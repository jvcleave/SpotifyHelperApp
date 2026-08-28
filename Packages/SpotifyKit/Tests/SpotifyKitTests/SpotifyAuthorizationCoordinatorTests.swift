import Foundation
import Testing
@testable import SpotifyKit

@Suite struct SpotifyAuthorizationCoordinatorTests {
    @Test func publicSignInUsesSessionConfigurationAndStoresTokens() async throws {
        let store = MemorySpotifyTokenStore()
        let transport = MockSpotifyHTTPTransport(responses: [
            successfulTokenResponse,
            response(statusCode: 204)
        ])
        let session = SpotifySession(
            configuration: SpotifyConfiguration(
                clientID: "shared-app-client",
                redirectPath: "/spotify-sign-in"
            ),
            transport: transport,
            tokenStore: store
        )
        let browser = TestAuthorizationBrowser(behavior: .authorize)
        let coordinator = SpotifyAuthorizationCoordinator(
            session: session,
            browser: browser,
            callbackTimeout: .seconds(5)
        )

        try await coordinator.connect()

        let authorizationURL = try #require(await browser.openedURLs.first)
        let query = try authorizationQuery(authorizationURL: authorizationURL)
        #expect(query["client_id"] == "shared-app-client")
        #expect(query["scope"] == "user-read-currently-playing")
        let redirectValue = try #require(query["redirect_uri"])
        let redirectURI = try #require(URL(string: redirectValue))
        #expect(redirectURI.path == "/spotify-sign-in")
        #expect(redirectURI.host == "127.0.0.1")
        #expect(redirectURI.port != nil)

        let tokenRequest = try #require(await transport.requests().first)
        let body = String(
            decoding: try #require(tokenRequest.httpBody),
            as: UTF8.self
        )
        let encodedBodyURL = try #require(URL(string: "https://test.invalid/?\(body)"))
        let fields = try authorizationQuery(authorizationURL: encodedBodyURL)
        #expect(fields["client_id"] == query["client_id"])
        #expect(fields["redirect_uri"] == query["redirect_uri"])
        #expect(fields["code"] == "test-code")
        #expect(fields["client_secret"] == nil)
        let codeVerifier = try #require(fields["code_verifier"])
        #expect(SpotifyAuthorization.codeChallenge(codeVerifier: codeVerifier) == query["code_challenge"])
        #expect(await store.savedToken()?.refreshToken == "test-refresh")
        #expect(try await session.restoreConnection())
        #expect(try await session.currentlyPlaying() == .nothingPlaying)
        await coordinator.cancel()
        #expect(await store.savedToken() != nil)
        try await session.disconnect()
        #expect(await store.savedToken() == nil)
    }

    @Test(arguments: [
        (TestAuthorizationBrowser.Behavior.denied, SpotifyError.authorizationDenied("access_denied")),
        (.mismatchedState, .authorizationStateMismatch),
        (.malformed, .invalidAuthorizationCallback)
    ])
    private func rejectedCallbackNeverExchangesTokens(
        behavior: TestAuthorizationBrowser.Behavior,
        expectedError: SpotifyError
    ) async throws {
        let setup = SignInTestSetup(behavior: behavior)
        await #expect(throws: expectedError) {
            try await setup.coordinator.connect()
        }
        #expect(await setup.transport.requests().isEmpty)
        #expect(await setup.store.savedToken() == nil)
        #expect(await !setup.callback.isRunning)
    }

    @Test func browserFailureClosesListener() async throws {
        let setup = SignInTestSetup(behavior: .failure)
        await #expect(throws: SpotifyError.network("Test browser could not open.")) {
            try await setup.coordinator.connect()
        }
        #expect(await !setup.callback.isRunning)
        #expect(await setup.transport.requests().isEmpty)
    }

    @Test func tokenExchangeFailureClosesListener() async throws {
        let setup = SignInTestSetup(
            behavior: .authorize,
            responses: [response(statusCode: 503)]
        )
        await #expect(throws: SpotifyError.server(
            statusCode: 503,
            message: "Spotify authorization failed."
        )) {
            try await setup.coordinator.connect()
        }
        #expect(await !setup.callback.isRunning)
        #expect(await setup.store.savedToken() == nil)
        #expect(await setup.transport.requests().count == 1)
    }

    @Test func callbackTimeoutIsReportedAndCleansUp() async throws {
        let setup = SignInTestSetup(
            behavior: .idle,
            timeout: .milliseconds(100)
        )
        await #expect(throws: SpotifyError.network("Spotify authorization timed out. Please try connecting again.")) {
            try await setup.coordinator.connect()
        }
        #expect(await !setup.callback.isRunning)
        #expect(await setup.store.savedToken() == nil)
    }

    @Test func callerCancellationCleansUpOwnedWork() async throws {
        let setup = SignInTestSetup(behavior: .idle)
        let connectionTask = Task { try await setup.coordinator.connect() }
        await setup.browser.waitUntilOpened()
        connectionTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await connectionTask.value
        }
        #expect(await !setup.callback.isRunning)
        #expect(await setup.transport.requests().isEmpty)
    }

    @Test func explicitCancellationWaitsAndIsRepeatable() async throws {
        let setup = SignInTestSetup(behavior: .idle)
        let connectionTask = Task { try await setup.coordinator.connect() }
        await setup.browser.waitUntilOpened()
        await setup.coordinator.cancel()
        await setup.coordinator.cancel()
        #expect(await !setup.callback.isRunning)
        await #expect(throws: CancellationError.self) {
            try await connectionTask.value
        }
        #expect(await setup.store.savedToken() == nil)
    }

    @Test func concurrentSignInIsRejectedWithoutDisturbingFirstAttempt() async throws {
        let setup = SignInTestSetup(behavior: .idle)
        let connectionTask = Task { try await setup.coordinator.connect() }
        await setup.browser.waitUntilOpened()
        await #expect(throws: SpotifyError.authorizationInProgress) {
            try await setup.coordinator.connect()
        }
        #expect(await setup.browser.openedURLs.count == 1)
        #expect(await setup.callback.isRunning)
        await setup.coordinator.cancel()
        await #expect(throws: CancellationError.self) {
            try await connectionTask.value
        }
    }

    @Test func retryCreatesFreshListenerAndPKCEState() async throws {
        let store = MemorySpotifyTokenStore()
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "client"),
            transport: MockSpotifyHTTPTransport(responses: [successfulTokenResponse]),
            tokenStore: store
        )
        let browser = TestAuthorizationBrowser(behavior: .denied)
        let coordinator = SpotifyAuthorizationCoordinator(
            session: session,
            browser: browser,
            callbackTimeout: .seconds(5)
        )
        await #expect(throws: SpotifyError.authorizationDenied("access_denied")) {
            try await coordinator.connect()
        }
        await browser.setBehavior(.authorize)
        try await coordinator.connect()
        let urls = await browser.openedURLs
        #expect(urls.count == 2)
        let first = try authorizationQuery(authorizationURL: urls[0])
        let second = try authorizationQuery(authorizationURL: urls[1])
        #expect(first["state"] != second["state"])
        #expect(first["code_challenge"] != second["code_challenge"])
        #expect(await store.savedToken() != nil)
    }

    @Test func cancellationDuringExchangeDoesNotSaveTokens() async throws {
        let store = MemorySpotifyTokenStore()
        let transport = WaitingTokenTransport()
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "client"),
            transport: transport,
            tokenStore: store
        )
        let coordinator = SpotifyAuthorizationCoordinator(
            session: session,
            browser: TestAuthorizationBrowser(behavior: .authorize),
            callbackTimeout: .seconds(5)
        )
        let connectionTask = Task { try await coordinator.connect() }
        await transport.waitUntilRequested()
        await coordinator.cancel()
        await #expect(throws: CancellationError.self) {
            try await connectionTask.value
        }
        #expect(await store.savedToken() == nil)
        #expect(await store.saveCount == 0)
    }
}

private let successfulTokenResponse = response(
    statusCode: 200,
    body: """
    {"access_token":"test-access","refresh_token":"test-refresh","token_type":"Bearer","expires_in":3600}
    """
)

private struct SignInTestSetup {
    let store: MemorySpotifyTokenStore
    let transport: MockSpotifyHTTPTransport
    let browser: TestAuthorizationBrowser
    let callback: SpotifyLoopbackCallbackServer
    let coordinator: SpotifyAuthorizationCoordinator

    init(
        behavior: TestAuthorizationBrowser.Behavior,
        responses: [SpotifyHTTPResponse] = [],
        timeout: Duration = .seconds(5)
    ) {
        store = MemorySpotifyTokenStore()
        transport = MockSpotifyHTTPTransport(responses: responses)
        browser = TestAuthorizationBrowser(behavior: behavior)
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "client"),
            transport: transport,
            tokenStore: store
        )
        let callback = SpotifyLoopbackCallbackServer(timeout: timeout)
        self.callback = callback
        coordinator = SpotifyAuthorizationCoordinator(
            session: session,
            browser: browser,
            callbackFactory: { callback }
        )
    }
}

private actor TestAuthorizationBrowser: SpotifyBrowserOpening {
    enum Behavior: Sendable {
        case authorize, denied, mismatchedState, malformed, idle, failure
    }

    private var behavior: Behavior
    private var openedWaiter: CheckedContinuation<Void, Never>?
    private(set) var openedURLs: [URL] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func open(_ authorizationURL: URL) async throws {
        openedURLs.append(authorizationURL)
        openedWaiter?.resume()
        openedWaiter = nil
        let query = try authorizationQuery(authorizationURL: authorizationURL)
        let redirectValue = try #require(query["redirect_uri"])
        var callback = try #require(URLComponents(string: redirectValue))
        var state = try #require(query["state"])
        let resultParameter: URLQueryItem
        switch behavior {
        case .idle:
            return
        case .failure:
            throw SpotifyError.network("Test browser could not open.")
        case .denied:
            resultParameter = URLQueryItem(
                name: "error",
                value: "access_denied"
            )
        case .mismatchedState:
            state = "wrong-state"
            resultParameter = URLQueryItem(
                name: "code",
                value: "test-code"
            )
        case .malformed:
            resultParameter = URLQueryItem(
                name: "code",
                value: ""
            )
        case .authorize:
            resultParameter = URLQueryItem(
                name: "code",
                value: "test-code"
            )
        }
        callback.queryItems = [
            resultParameter,
            URLQueryItem(
                name: "state",
                value: state
            )
        ]
        let callbackURL = try #require(callback.url)
        try #require(callbackURL.host == "127.0.0.1")
        let client = URLSession(configuration: .ephemeral)
        defer { client.finishTasksAndInvalidate() }
        let (_, response) = try await client.data(from: callbackURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    func waitUntilOpened() async {
        if openedURLs.isEmpty {
            await withCheckedContinuation { continuation in
                openedWaiter = continuation
            }
        }
    }
}

private func authorizationQuery(authorizationURL: URL) throws -> [String: String] {
    let components = try #require(URLComponents(
        url: authorizationURL,
        resolvingAgainstBaseURL: false
    ))
    var values: [String: String] = [:]
    for queryItem in components.queryItems ?? [] {
        values[queryItem.name] = queryItem.value
    }
    return values
}

private actor WaitingTokenTransport: SpotifyHTTPTransport {
    private var receivedRequest = false
    private var requestWaiter: CheckedContinuation<Void, Never>?

    func send(_ request: URLRequest) async throws -> SpotifyHTTPResponse {
        receivedRequest = true
        requestWaiter?.resume()
        requestWaiter = nil
        try await Task.sleep(for: .seconds(30))
        return successfulTokenResponse
    }

    func waitUntilRequested() async {
        if !receivedRequest {
            await withCheckedContinuation { continuation in
                requestWaiter = continuation
            }
        }
    }
}
