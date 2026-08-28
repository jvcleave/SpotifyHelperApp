import Foundation
import Testing
@testable import SpotifyKit

@Test func authorizationExchangesCodeAndStoresToken() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let transport = MockSpotifyHTTPTransport(
        responses: [
            response(
                statusCode: 200,
                body: """
                {
                  "access_token": "access-token",
                  "token_type": "Bearer",
                  "scope": "user-read-currently-playing",
                  "expires_in": 3600,
                  "refresh_token": "refresh-token"
                }
                """
            )
        ]
    )
    let tokenStore = MemorySpotifyTokenStore()
    let session = SpotifySession(
        configuration: SpotifyConfiguration(clientID: "client-id"),
        transport: transport,
        tokenStore: tokenStore,
        now: { fixedDate }
    )
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))

    try await session.authorize(
        code: "authorization-code",
        codeVerifier: String(repeating: "a", count: 43),
        redirectURI: redirectURI
    )

    let storedToken = await tokenStore.savedToken()
    #expect(storedToken?.accessToken == "access-token")
    #expect(storedToken?.refreshToken == "refresh-token")
    #expect(storedToken?.expiresAt == fixedDate.addingTimeInterval(3600))

    let requests = await transport.requests()
    let request = try #require(requests.first)
    let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    #expect(request.url?.absoluteString == "https://accounts.spotify.com/api/token")
    #expect(request.httpMethod == "POST")
    #expect(body.contains("client_id=client-id"))
    #expect(body.contains("code=authorization-code"))
    #expect(body.contains("code_verifier="))
}

@Test func currentlyPlayingDecodesTrackSnapshot() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let token = SpotifyToken(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        tokenType: "Bearer",
        scopes: ["user-read-currently-playing"],
        expiresAt: fixedDate.addingTimeInterval(3600)
    )
    let transport = MockSpotifyHTTPTransport(
        responses: [
            response(
                statusCode: 200,
                body: """
                {
                  "timestamp": 1800000000000,
                  "progress_ms": 63125,
                  "is_playing": true,
                  "currently_playing_type": "track",
                  "item": {
                    "id": "track-id",
                    "uri": "spotify:track:track-id",
                    "name": "Test Song",
                    "type": "track",
                    "artists": [{ "name": "First Artist" }, { "name": "Second Artist" }],
                    "album": { "name": "Test Album" },
                    "duration_ms": 201000,
                    "external_urls": { "spotify": "https://open.spotify.com/track/track-id" }
                  }
                }
                """
            )
        ]
    )
    let session = SpotifySession(
        configuration: SpotifyConfiguration(clientID: "client-id"),
        transport: transport,
        tokenStore: MemorySpotifyTokenStore(token: token),
        now: { fixedDate }
    )

    let content = try await session.currentlyPlaying()

    if case .track(let track) = content {
        #expect(track.id == "track-id")
        #expect(track.title == "Test Song")
        #expect(track.artists == ["First Artist", "Second Artist"])
        #expect(track.albumTitle == "Test Album")
        #expect(track.durationMilliseconds == 201000)
        #expect(track.progressMilliseconds == 63125)
        #expect(track.isPlaying)
        #expect(track.sampledAt == fixedDate)
        #expect(track.spotifyURL?.absoluteString == "https://open.spotify.com/track/track-id")
    } else {
        Issue.record("Expected track playback content.")
    }
}

@Test func emptyPlaybackResponseIsNotAnError() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let token = SpotifyToken(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        tokenType: "Bearer",
        scopes: ["user-read-currently-playing"],
        expiresAt: fixedDate.addingTimeInterval(3600)
    )
    let transport = MockSpotifyHTTPTransport(
        responses: [response(statusCode: 204)]
    )
    let session = SpotifySession(
        configuration: SpotifyConfiguration(clientID: "client-id"),
        transport: transport,
        tokenStore: MemorySpotifyTokenStore(token: token),
        now: { fixedDate }
    )

    let content = try await session.currentlyPlaying()

    #expect(content == .nothingPlaying)
}

@Test func expiredAccessTokenRefreshesAndPreservesRefreshToken() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let originalToken = SpotifyToken(
        accessToken: "expired-access-token",
        refreshToken: "original-refresh-token",
        tokenType: "Bearer",
        scopes: ["user-read-currently-playing"],
        expiresAt: fixedDate.addingTimeInterval(-1)
    )
    let transport = MockSpotifyHTTPTransport(
        responses: [
            response(
                statusCode: 200,
                body: """
                {
                  "access_token": "fresh-access-token",
                  "token_type": "Bearer",
                  "scope": "user-read-currently-playing",
                  "expires_in": 3600
                }
                """
            ),
            response(statusCode: 204)
        ]
    )
    let tokenStore = MemorySpotifyTokenStore(token: originalToken)
    let session = SpotifySession(
        configuration: SpotifyConfiguration(clientID: "client-id"),
        transport: transport,
        tokenStore: tokenStore,
        now: { fixedDate }
    )

    _ = try await session.currentlyPlaying()

    let storedToken = await tokenStore.savedToken()
    #expect(storedToken?.accessToken == "fresh-access-token")
    #expect(storedToken?.refreshToken == "original-refresh-token")
    let requests = await transport.requests()
    #expect(requests.count == 2)
    #expect(requests[0].url?.host == "accounts.spotify.com")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access-token")
}

@Test func unauthorizedPlaybackRefreshesAndRetriesOnce() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let token = SpotifyToken(
        accessToken: "rejected-access-token",
        refreshToken: "refresh-token",
        tokenType: "Bearer",
        scopes: ["user-read-currently-playing"],
        expiresAt: fixedDate.addingTimeInterval(3600)
    )
    let transport = MockSpotifyHTTPTransport(
        responses: [
            response(statusCode: 401),
            response(
                statusCode: 200,
                body: """
                {
                  "access_token": "fresh-access-token",
                  "token_type": "Bearer",
                  "scope": "user-read-currently-playing",
                  "expires_in": 3600
                }
                """
            ),
            response(statusCode: 204)
        ]
    )
    let session = SpotifySession(
        configuration: SpotifyConfiguration(clientID: "client-id"),
        transport: transport,
        tokenStore: MemorySpotifyTokenStore(token: token),
        now: { fixedDate }
    )

    let content = try await session.currentlyPlaying()

    #expect(content == .nothingPlaying)
    let requests = await transport.requests()
    #expect(requests.count == 3)
}

@Test func rateLimitIncludesRetryDelay() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let token = SpotifyToken(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        tokenType: "Bearer",
        scopes: ["user-read-currently-playing"],
        expiresAt: fixedDate.addingTimeInterval(3600)
    )
    let transport = MockSpotifyHTTPTransport(
        responses: [
            response(
                statusCode: 429,
                headers: ["Retry-After": "12"]
            )
        ]
    )
    let session = SpotifySession(
        configuration: SpotifyConfiguration(clientID: "client-id"),
        transport: transport,
        tokenStore: MemorySpotifyTokenStore(token: token),
        now: { fixedDate }
    )

    do {
        _ = try await session.currentlyPlaying()
        Issue.record("A rate-limited response should throw.")
    } catch let error as SpotifyError {
        #expect(error == .rateLimited(retryAfter: 12))
    }
}

