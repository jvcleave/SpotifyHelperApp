import Foundation

/// A presentation-independent sign-in boundary for apps and test doubles.
public protocol SpotifyAuthorizing: Sendable {
    func connect() async throws
    func cancel() async
}

// Keep listener substitution internal; consumers only need the browser boundary.
protocol SpotifyAuthorizationCallbackReceiving: Sendable {
    func start() async throws -> URL
    func waitForCallback() async throws -> URL
    func stop() async
}

/// Owns a complete browser sign-in attempt for a Spotify session.
/// Keep one coordinator per session. Constructing it does not open the browser
/// or read tokens. Call `connect()` only in response to a user action.
public actor SpotifyAuthorizationCoordinator: SpotifyAuthorizing {
    private struct Attempt {
        let id: UUID
        let task: Task<Void, any Error>
        let callback: any SpotifyAuthorizationCallbackReceiving
    }

    private let session: SpotifySession
    private let browser: any SpotifyBrowserOpening
    private let callbackFactory: @Sendable () -> any SpotifyAuthorizationCallbackReceiving
    private var activeAttempt: Attempt?

    public init(
        session: SpotifySession,
        browser: any SpotifyBrowserOpening = SystemSpotifyBrowser(),
        callbackTimeout: Duration = .seconds(120)
    ) {
        self.session = session
        self.browser = browser
        let callbackPath = session.configuration.redirectPath
        let callbackPort = session.configuration.redirectPort
        callbackFactory = {
            SpotifyLoopbackCallbackServer(
                callbackPath: callbackPath,
                callbackPort: callbackPort,
                timeout: callbackTimeout
            )
        }
    }

    init(
        session: SpotifySession,
        browser: any SpotifyBrowserOpening,
        callbackFactory: @escaping @Sendable () -> any SpotifyAuthorizationCallbackReceiving
    ) {
        self.session = session
        self.browser = browser
        self.callbackFactory = callbackFactory
    }

    /// Opens the browser and returns only after the callback is verified and
    /// tokens are saved. A second concurrent attempt is rejected.
    public func connect() async throws {
        try Task.checkCancellation()
        if activeAttempt != nil {
            throw SpotifyError.authorizationInProgress
        }

        let attemptID = UUID()
        let callback = callbackFactory()
        let authorization = SpotifyAuthorization(configuration: session.configuration)
        let task = Task<Void, any Error> { [session, browser] in
            do {
                try Task.checkCancellation()
                let redirectURI = try await callback.start()
                try Task.checkCancellation()
                let request = try authorization.makeRequest(redirectURI: redirectURI)
                try await browser.open(request.authorizationURL)
                try Task.checkCancellation()
                let callbackURL = try await callback.waitForCallback()
                try Task.checkCancellation()
                let code = try authorization.authorizationCode(
                    callbackURL: callbackURL,
                    request: request
                )
                try await session.authorize(
                    code: code,
                    codeVerifier: request.codeVerifier,
                    redirectURI: request.redirectURI
                )
                try Task.checkCancellation()
                await callback.stop()
            } catch {
                await callback.stop()
                throw error
            }
        }
        activeAttempt = Attempt(
            id: attemptID,
            task: task,
            callback: callback
        )
        defer {
            if activeAttempt?.id == attemptID {
                activeAttempt = nil
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
            Task { await callback.stop() }
        }
    }

    /// Cancels and waits for owned work to finish. Safe to repeat. This does not
    /// erase an existing session; call the session's `disconnect()` afterward
    /// when the user wants to remove saved authorization.
    public func cancel() async {
        if let attempt = activeAttempt {
            attempt.task.cancel()
            await attempt.callback.stop()
            _ = await attempt.task.result
            if activeAttempt?.id == attempt.id {
                activeAttempt = nil
            }
        }
    }
}
