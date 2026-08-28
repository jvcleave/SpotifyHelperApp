import Foundation
import Network

/// One authorization attempt. The server owns its listener, connections, and timeout.
public actor SpotifyLoopbackCallbackServer: SpotifyAuthorizationCallbackReceiving {
    private let callbackPath: String
    private let timeout: Duration
    private let queue = DispatchQueue(label: "com.jvclabs.SpotifyHelperApp.oauth-callback")
    private var listener: NWListener?
    private var started = false
    private var finished = false
    private var port: UInt16?
    private var connections: [UUID: NWConnection] = [:]
    private var requestBuffers: [UUID: Data] = [:]
    private var timeoutTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<URL, any Error>?
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var callbackResult: Result<URL, any Error>?

    public init(
        callbackPath: String = "/callback",
        timeout: Duration = .seconds(120)
    ) {
        self.callbackPath = callbackPath
        self.timeout = timeout
    }

    public func start() async throws -> URL {
        try Task.checkCancellation()
        if started || finished {
            throw SpotifyError.invalidConfiguration("Create a new callback server for each authorization attempt.")
        }
        started = true

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: "127.0.0.1",
                        port: .any
                    )
                    let listener = try NWListener(
                        using: parameters,
                        on: .any
                    )
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        let boundPort = listener?.port?.rawValue
                        Task {
                            await self?.listenerStateChanged(
                                state: state,
                                boundPort: boundPort
                            )
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task {
                            if let self {
                                await self.acceptConnection(connection)
                            } else {
                                connection.cancel()
                            }
                        }
                    }
                    listener.start(queue: queue)
                    let timeout = self.timeout
                    timeoutTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                            await self?.finish(.failure(
                                SpotifyError.network("Spotify authorization timed out. Please try connecting again.")
                            ))
                        } catch {
                            // Cleanup cancels the deadline after this attempt finishes.
                        }
                    }
                } catch {
                    finish(.failure(error))
                }
            }
        } onCancel: {
            Task {
                await self.stop()
            }
        }
    }

    public func waitForCallback() async throws -> URL {
        if Task.isCancelled {
            stop()
            throw CancellationError()
        }
        if let callbackResult {
            return try callbackResult.get()
        }
        if !started || callbackContinuation != nil {
            throw SpotifyError.invalidConfiguration("The callback server requires one active authorization attempt.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callbackContinuation = continuation
            }
        } onCancel: {
            Task {
                await self.stop()
            }
        }
    }

    public func stop() {
        finish(.failure(CancellationError()))
    }

    var isRunning: Bool {
        listener != nil
    }

    private func listenerStateChanged(
        state: NWListener.State,
        boundPort: UInt16?
    ) {
        if finished {
            return
        }
        switch state {
        case .ready:
            if let boundPort, let continuation = startContinuation {
                port = boundPort
                var components = URLComponents()
                components.scheme = "http"
                components.host = "127.0.0.1"
                components.port = Int(boundPort)
                components.path = callbackPath
                if let redirectURI = components.url {
                    startContinuation = nil
                    continuation.resume(returning: redirectURI)
                    return
                }
            }
            finish(.failure(SpotifyError.invalidAuthorizationCallback))
        case .failed:
            finish(.failure(SpotifyError.network("The local Spotify callback listener could not start.")))
        case .cancelled:
            finish(.failure(CancellationError()))
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func acceptConnection(_ connection: NWConnection) {
        if finished || connections.count >= 4 {
            connection.cancel()
            return
        }
        let connectionID = UUID()
        connections[connectionID] = connection
        requestBuffers[connectionID] = Data()
        connection.start(queue: queue)
        receiveRequest(connectionID: connectionID)
    }

    private func receiveRequest(connectionID: UUID) {
        if let connection = connections[connectionID] {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 16_384
            ) { [weak self] data, _, isComplete, error in
                Task {
                    await self?.receivedBytes(
                        connectionID: connectionID,
                        data: data,
                        ended: isComplete || error != nil
                    )
                }
            }
        }
    }

    private func receivedBytes(
        connectionID: UUID,
        data: Data?,
        ended: Bool
    ) {
        if finished || connections[connectionID] == nil {
            return
        }
        if let data {
            requestBuffers[connectionID, default: Data()].append(data)
        }
        let buffer = requestBuffers[connectionID] ?? Data()
        if buffer.count > 16_384 {
            respond(
                connectionID: connectionID,
                status: "431 Request Header Fields Too Large",
                callbackURL: nil
            )
            return
        }
        if buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            if ended {
                connections.removeValue(forKey: connectionID)?.cancel()
                requestBuffers.removeValue(forKey: connectionID)
            } else {
                receiveRequest(connectionID: connectionID)
            }
            return
        }

        let requestText = String(
            decoding: buffer,
            as: UTF8.self
        )
        let requestLine = requestText.components(separatedBy: "\r\n")[0]
        let requestParts = requestLine.split(separator: " ")
        if requestParts.count == 3,
           requestParts[0] == "GET",
           requestParts[1].hasPrefix("/"),
           let port,
           var components = URLComponents(string: String(requestParts[1])),
           components.path == callbackPath,
           components.host == nil,
           components.fragment == nil {
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = Int(port)
            if let callbackURL = components.url {
                respond(
                    connectionID: connectionID,
                    status: "200 OK",
                    callbackURL: callbackURL
                )
                return
            }
        }
        // Browser favicon requests must not abort the authorization attempt.
        respond(
            connectionID: connectionID,
            status: "404 Not Found",
            callbackURL: nil
        )
    }

    private func respond(
        connectionID: UUID,
        status: String,
        callbackURL: URL?
    ) {
        if let connection = connections[connectionID] {
            let message = callbackURL == nil
                ? "This callback request is not recognized."
                : "Spotify response received. Return to SpotifyHelperApp to finish connecting."
            let bodyData = Data(message.utf8)
            let headers = [
                "HTTP/1.1 \(status)",
                "Content-Type: text/plain; charset=utf-8",
                "Content-Length: \(bodyData.count)",
                "Cache-Control: no-store",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n")
            var responseData = Data(headers.utf8)
            responseData.append(bodyData)
            connection.send(
                content: responseData,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    Task {
                        await self?.responseSent(
                            connectionID: connectionID,
                            callbackURL: callbackURL
                        )
                    }
                }
            )
        }
    }

    private func responseSent(
        connectionID: UUID,
        callbackURL: URL?
    ) {
        connections.removeValue(forKey: connectionID)?.cancel()
        requestBuffers.removeValue(forKey: connectionID)
        if let callbackURL {
            finish(.success(callbackURL))
        }
    }

    private func finish(_ result: Result<URL, any Error>) {
        if finished {
            return
        }
        finished = true
        callbackResult = result
        timeoutTask?.cancel()
        timeoutTask = nil
        if let startContinuation {
            self.startContinuation = nil
            switch result {
            case .failure(let error):
                startContinuation.resume(throwing: error)
            case .success:
                startContinuation.resume(throwing: SpotifyError.invalidAuthorizationCallback)
            }
        }
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(with: result)
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        requestBuffers.removeAll()
    }
}
