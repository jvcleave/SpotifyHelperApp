import Foundation
import Testing
@testable import SpotifyKit

@Suite struct SpotifyRecoveryTests {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let refreshedTokenJSON = """
    {"access_token":"fresh","token_type":"Bearer","expires_in":3600}
    """

    func makeSession(
        responses: [SpotifyHTTPResponse],
        expired: Bool = false
    ) -> (SpotifySession, MockSpotifyHTTPTransport, MemorySpotifyTokenStore) {
        let token = SpotifyToken(
            accessToken: "access",
            refreshToken: "refresh+token",
            tokenType: "Bearer",
            scopes: ["user-read-currently-playing"],
            expiresAt: fixedDate.addingTimeInterval(expired ? -1 : 3600)
        )
        let transport = MockSpotifyHTTPTransport(responses: responses)
        let store = MemorySpotifyTokenStore(token: token)
        let date = fixedDate
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "client"),
            transport: transport,
            tokenStore: store,
            now: { date }
        )
        return (session, transport, store)
    }

    @Test func repeatedUnauthorizedResponseClearsSavedConnection() async throws {
        let (session, transport, store) = makeSession(responses: [
            response(statusCode: 401),
            response(
                statusCode: 200,
                body: refreshedTokenJSON
            ),
            response(statusCode: 401)
        ])
        await #expect(throws: SpotifyError.notConnected) {
            try await session.currentlyPlaying()
        }
        #expect(await store.savedToken() == nil)
        #expect(await transport.requests().count == 3)
        #expect(try await !session.restoreConnection())
    }

    @Test func revokedRefreshTokenRequiresReconnection() async throws {
        let (session, transport, store) = makeSession(
            responses: [response(
                statusCode: 400,
                body: #"{"error":"invalid_grant"}"#
            )],
            expired: true
        )
        await #expect(throws: SpotifyError.notConnected) {
            try await session.currentlyPlaying()
        }
        #expect(await store.savedToken() == nil)
        #expect(await transport.requests().count == 1)
    }

    @Test func retryAfterPreventsImmediateManualRetry() async throws {
        let (session, transport, _) = makeSession(responses: [response(
            statusCode: 429,
            headers: ["Retry-After": "20"]
        )])
        for _ in 0..<2 {
            await #expect(throws: SpotifyError.rateLimited(retryAfter: 20)) {
                try await session.currentlyPlaying()
            }
        }
        #expect(await transport.requests().count == 1)
    }

    @Test func tokenEndpointRateLimitAlsoEnforcesCooldown() async throws {
        let (session, transport, _) = makeSession(
            responses: [response(
                statusCode: 429,
                headers: ["Retry-After": "30"]
            )],
            expired: true
        )
        for _ in 0..<2 {
            await #expect(throws: SpotifyError.rateLimited(retryAfter: 30)) {
                try await session.currentlyPlaying()
            }
        }
        #expect(await transport.requests().count == 1)
    }

    @Test func refreshWithoutScopePreservesScopeAndEncodesPlus() async throws {
        let (session, transport, store) = makeSession(
            responses: [
                response(
                    statusCode: 200,
                    body: refreshedTokenJSON
                ),
                response(statusCode: 204)
            ],
            expired: true
        )
        _ = try await session.currentlyPlaying()
        #expect(await store.savedToken()?.scopes == ["user-read-currently-playing"])
        let requests = await transport.requests()
        let body = String(
            decoding: try #require(requests.first?.httpBody),
            as: UTF8.self
        )
        #expect(body.contains("refresh_token=refresh%2Btoken"))
    }

    @Test func concurrentReadsRefreshOnlyOnce() async throws {
        let (session, transport, _) = makeSession(
            responses: [
                response(
                    statusCode: 200,
                    body: refreshedTokenJSON
                ),
                response(statusCode: 204),
                response(statusCode: 204)
            ],
            expired: true
        )
        async let first = session.currentlyPlaying()
        async let second = session.currentlyPlaying()
        #expect(try await first == .nothingPlaying)
        #expect(try await second == .nothingPlaying)
        #expect(await transport.requests().count == 3)
    }

    @Test func forbiddenResponseRetainsConnection() async throws {
        let (session, _, store) = makeSession(responses: [response(
            statusCode: 403,
            body: #"{"error":{"status":403,"message":"Account not allowlisted"}}"#
        )])
        await #expect(throws: SpotifyError.forbidden("Account not allowlisted")) {
            try await session.currentlyPlaying()
        }
        #expect(await store.savedToken() != nil)
    }

    @Test func malformedPlaybackIsRecoverable() async throws {
        let (session, _, _) = makeSession(responses: [response(
            statusCode: 200,
            body: "not json"
        )])
        await #expect(throws: SpotifyError.invalidResponse) {
            try await session.currentlyPlaying()
        }
    }

    @Test(arguments: ["episode", "ad", "future-type"])
    func nonTrackContentIsUnsupported(contentType: String) async throws {
        let (session, _, _) = makeSession(responses: [response(
            statusCode: 200,
            body: """
            {"is_playing":true,"currently_playing_type":"\(contentType)","item":null}
            """
        )])
        #expect(try await session.currentlyPlaying() == .unsupported(
            SpotifyUnsupportedPlayback(
                type: contentType,
                title: nil
            )
        ))
    }

    @Test func missingProgressIsNotReportedAsZero() async throws {
        let (session, _, _) = makeSession(responses: [response(
            statusCode: 200,
            body: """
            {"is_playing":false,"currently_playing_type":"track","progress_ms":null,
             "item":{"id":"id","name":"Song","duration_ms":120000}}
            """
        )])
        let content = try await session.currentlyPlaying()
        if case .track(let track) = content {
            #expect(track.progressMilliseconds == nil)
            #expect(!track.isPlaying)
        } else {
            Issue.record("Expected track content")
        }
    }

    @Test func disconnectIsRepeatable() async throws {
        let (session, transport, store) = makeSession(responses: [])
        try await session.disconnect()
        try await session.disconnect()
        #expect(await store.savedToken() == nil)
        #expect(try await !session.restoreConnection())
        #expect(await transport.requests().isEmpty)
    }

    @Test func networkLossKeepsStoredAuthorization() async throws {
        let store = MemorySpotifyTokenStore(token: SpotifyToken(
            accessToken: "access",
            refreshToken: "refresh",
            tokenType: "Bearer",
            scopes: ["user-read-currently-playing"],
            expiresAt: .distantFuture
        ))
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "client"),
            transport: OfflineSpotifyTransport(),
            tokenStore: store
        )
        await #expect(throws: SpotifyError.network("Spotify could not be reached. Check the network connection and try again.")) {
            try await session.currentlyPlaying()
        }
        #expect(await store.savedToken() != nil)
    }

    @Test func cancelledRequestDoesNotPublishOrSaveToken() async throws {
        let transport = SuspendedSpotifyTransport(response: response(
            statusCode: 200,
            body: """
            {"access_token":"access","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh"}
            """
        ))
        let store = MemorySpotifyTokenStore()
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "client"),
            transport: transport,
            tokenStore: store
        )
        let requestTask = Task {
            try await session.authorize(
                code: "code",
                codeVerifier: String(
                    repeating: "a",
                    count: 43
                ),
                redirectURI: URL(string: "http://127.0.0.1:8000/callback")!
            )
        }
        await transport.waitForRequest()
        requestTask.cancel()
        let disconnectTask = Task { try await session.disconnect() }
        await transport.releaseResponse()
        await #expect(throws: CancellationError.self) { try await requestTask.value }
        try await disconnectTask.value
        #expect(await store.savedToken() == nil)
        #expect(await store.saveCount == 0)
    }
}

private struct OfflineSpotifyTransport: SpotifyHTTPTransport {
    func send(_ request: URLRequest) async throws -> SpotifyHTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private actor SuspendedSpotifyTransport: SpotifyHTTPTransport {
    let response: SpotifyHTTPResponse
    var responseContinuation: CheckedContinuation<Void, Never>?
    var requestContinuation: CheckedContinuation<Void, Never>?
    var receivedRequest = false

    init(response: SpotifyHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async -> SpotifyHTTPResponse {
        receivedRequest = true
        requestContinuation?.resume()
        requestContinuation = nil
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
        return response
    }

    func waitForRequest() async {
        if !receivedRequest {
            await withCheckedContinuation { continuation in
                requestContinuation = continuation
            }
        }
    }

    func releaseResponse() {
        responseContinuation?.resume()
        responseContinuation = nil
    }
}
