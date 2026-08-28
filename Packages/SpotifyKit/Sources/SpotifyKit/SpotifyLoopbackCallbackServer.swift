import Foundation
import Network

public actor SpotifyLoopbackCallbackServer {
    private let callbackPath: String
    private let queue = DispatchQueue(label: "com.jvclabs.SpotifyHelperApp.oauth-callback")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, any Error>?
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var callbackResult: Result<URL, any Error>?

    public init(callbackPath: String = "/callback") {
        self.callbackPath = callbackPath
    }

    public func start() async throws -> URL {
        if listener != nil {
            throw SpotifyError.invalidConfiguration("A Spotify authorization request is already active.")
        }

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
                        switch state {
                        case .ready:
                            let port = listener?.port?.rawValue
                            Task {
                                await self?.listenerReady(port: port)
                            }
                        case .failed(let error):
                            let message = error.localizedDescription
                            Task {
                                await self?.listenerFailed(message: message)
                            }
                        case .cancelled:
                            Task {
                                await self?.listenerCancelled()
                            }
                        case .setup, .waiting:
                            break
                        @unknown default:
                            break
                        }
                    }

                    listener.newConnectionHandler = { [weak self, weak listener] connection in
                        if let callbackServer = self {
                            let port = listener?.port?.rawValue
                            Self.receiveHTTPRequest(
                                connection: connection,
                                callbackPath: callbackServer.callbackPath,
                                port: port,
                                queue: callbackServer.queue
                            ) { [callbackServer] result in
                                Task {
                                    await callbackServer.receiveCallback(result: result)
                                }
                            }
                        } else {
                            connection.cancel()
                        }
                    }
                    listener.start(queue: queue)
                } catch {
                    startContinuation = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task {
                await self.stop()
            }
        }
    }

    public func waitForCallback() async throws -> URL {
        if let callbackResult {
            self.callbackResult = nil
            return try callbackResult.get()
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
        let cancellationError = CancellationError()
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: cancellationError)
        }
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(throwing: cancellationError)
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        callbackResult = nil
    }

    var isRunning: Bool {
        listener != nil
    }

    private func listenerReady(port: UInt16?) {
        if let port, let continuation = startContinuation {
            var components = URLComponents()
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = Int(port)
            components.path = callbackPath
            if let redirectURI = components.url {
                startContinuation = nil
                continuation.resume(returning: redirectURI)
                return
            }
        }
        listenerFailed(message: "The Spotify authorization callback address could not be created.")
    }

    private func listenerFailed(message: String) {
        let error = SpotifyError.network(message)
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: error)
        }
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(throwing: error)
        } else {
            callbackResult = .failure(error)
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func listenerCancelled() {
        if listener != nil {
            listenerFailed(message: "Spotify authorization was cancelled.")
        }
    }

    private func receiveCallback(result: Result<URL, SpotifyError>) {
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(with: result.mapError { $0 as any Error })
        } else {
            callbackResult = result.mapError { $0 as any Error }
        }

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private nonisolated static func receiveHTTPRequest(
        connection: NWConnection,
        callbackPath: String,
        port: UInt16?,
        queue: DispatchQueue,
        completion: @escaping @Sendable (Result<URL, SpotifyError>) -> Void
    ) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16_384
        ) { data, _, _, error in
            let result: Result<URL, SpotifyError>
            let responseStatus: String
            let responseBody: String

            if let error {
                result = .failure(.network(error.localizedDescription))
                responseStatus = "400 Bad Request"
                responseBody = "Spotify authorization could not be completed."
            } else if let data,
                      let requestText = String(data: data, encoding: .utf8),
                      let requestLine = requestText.components(separatedBy: "\r\n").first {
                let requestParts = requestLine.split(separator: " ")
                if requestParts.count >= 2,
                   requestParts[0] == "GET",
                   let port {
                    let requestTarget = String(requestParts[1])
                    var targetComponents = URLComponents(string: requestTarget)
                    if targetComponents?.path == callbackPath {
                        targetComponents?.scheme = "http"
                        targetComponents?.host = "127.0.0.1"
                        targetComponents?.port = Int(port)
                        if let callbackURL = targetComponents?.url {
                            result = .success(callbackURL)
                            responseStatus = "200 OK"
                            responseBody = "Spotify is connected. You can return to SpotifyHelperApp."
                        } else {
                            result = .failure(.invalidAuthorizationCallback)
                            responseStatus = "400 Bad Request"
                            responseBody = "Spotify authorization returned an invalid callback."
                        }
                    } else {
                        result = .failure(.invalidAuthorizationCallback)
                        responseStatus = "404 Not Found"
                        responseBody = "This callback path is not recognized."
                    }
                } else {
                    result = .failure(.invalidAuthorizationCallback)
                    responseStatus = "400 Bad Request"
                    responseBody = "Spotify authorization returned an invalid request."
                }
            } else {
                result = .failure(.invalidAuthorizationCallback)
                responseStatus = "400 Bad Request"
                responseBody = "Spotify authorization returned an invalid request."
            }

            let bodyData = Data(responseBody.utf8)
            let headers = """
            HTTP/1.1 \(responseStatus)\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(bodyData.count)\r
            Connection: close\r
            \r
            """
            var responseData = Data(headers.utf8)
            responseData.append(bodyData)
            connection.send(
                content: responseData,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    completion(result)
                }
            )
        }
    }
}
