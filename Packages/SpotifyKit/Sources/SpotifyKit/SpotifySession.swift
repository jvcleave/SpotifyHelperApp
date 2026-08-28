import Foundation

public actor SpotifySession {
    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String
        let scope: String
        let expiresIn: Int
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case scope
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let status: Int?
            let message: String
        }

        let error: APIError
    }

    private let configuration: SpotifyConfiguration
    private let transport: any SpotifyHTTPTransport
    private let tokenStore: any SpotifyTokenStoring
    private let now: @Sendable () -> Date
    private var cachedToken: SpotifyToken?
    private var loadedStoredToken = false

    public init(
        configuration: SpotifyConfiguration,
        transport: any SpotifyHTTPTransport = URLSessionSpotifyHTTPTransport(),
        tokenStore: any SpotifyTokenStoring = KeychainSpotifyTokenStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.tokenStore = tokenStore
        self.now = now
    }

    public func restoreConnection() async throws -> Bool {
        try await loadStoredTokenIfNeeded()
        return cachedToken != nil
    }

    public func authorize(
        code: String,
        codeVerifier: String,
        redirectURI: URL
    ) async throws {
        let bodyValues = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": configuration.clientID,
            "code_verifier": codeVerifier
        ]
        let response = try await sendTokenRequest(bodyValues: bodyValues)
        if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
            let token = SpotifyToken(
                accessToken: response.accessToken,
                refreshToken: refreshToken,
                tokenType: response.tokenType,
                scopes: Self.scopes(scope: response.scope),
                expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn))
            )
            try await tokenStore.save(token)
            cachedToken = token
            loadedStoredToken = true
        } else {
            throw SpotifyError.invalidResponse
        }
    }

    public func disconnect() async throws {
        cachedToken = nil
        loadedStoredToken = true
        try await tokenStore.delete()
    }

    public func currentlyPlaying() async throws -> SpotifyPlaybackContent {
        let accessToken = try await validAccessToken(forceRefresh: false)
        var response = try await sendCurrentlyPlaying(accessToken: accessToken)
        if response.statusCode == 401 {
            let refreshedAccessToken = try await validAccessToken(forceRefresh: true)
            response = try await sendCurrentlyPlaying(accessToken: refreshedAccessToken)
        }

        switch response.statusCode {
        case 200:
            if response.data.isEmpty {
                return .nothingPlaying
            }
            return try decodePlayback(data: response.data)
        case 204:
            return .nothingPlaying
        case 401:
            throw SpotifyError.notConnected
        case 403:
            let message = apiErrorMessage(data: response.data)
                ?? "Spotify did not allow access to the current playback state. Check the account allowlist and requested scope."
            throw SpotifyError.forbidden(message)
        case 429:
            let retryAfter = response.header(name: "Retry-After").flatMap(TimeInterval.init)
            throw SpotifyError.rateLimited(retryAfter: retryAfter)
        default:
            let message = apiErrorMessage(data: response.data) ?? "Spotify could not load the current playback state."
            throw SpotifyError.server(
                statusCode: response.statusCode,
                message: message
            )
        }
    }

    private func loadStoredTokenIfNeeded() async throws {
        if !loadedStoredToken {
            cachedToken = try await tokenStore.load()
            loadedStoredToken = true
        }
    }

    private func validAccessToken(forceRefresh: Bool) async throws -> String {
        try await loadStoredTokenIfNeeded()
        if let token = cachedToken {
            let refreshThreshold = now().addingTimeInterval(30)
            if !forceRefresh && token.expiresAt > refreshThreshold {
                return token.accessToken
            }
            return try await refreshAccessToken(token: token)
        }
        throw SpotifyError.notConnected
    }

    private func refreshAccessToken(token: SpotifyToken) async throws -> String {
        let bodyValues = [
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": configuration.clientID
        ]

        do {
            let response = try await sendTokenRequest(bodyValues: bodyValues)
            let replacementRefreshToken: String
            if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
                replacementRefreshToken = refreshToken
            } else {
                replacementRefreshToken = token.refreshToken
            }
            let refreshedToken = SpotifyToken(
                accessToken: response.accessToken,
                refreshToken: replacementRefreshToken,
                tokenType: response.tokenType,
                scopes: Self.scopes(scope: response.scope),
                expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn))
            )
            try await tokenStore.save(refreshedToken)
            cachedToken = refreshedToken
            return refreshedToken.accessToken
        } catch let spotifyError as SpotifyError {
            if case .notConnected = spotifyError {
                cachedToken = nil
                try? await tokenStore.delete()
            }
            throw spotifyError
        }
    }

    private func sendTokenRequest(bodyValues: [String: String]) async throws -> TokenResponse {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedData(values: bodyValues)

        let response = try await send(request)
        if response.statusCode == 200 {
            do {
                return try JSONDecoder().decode(TokenResponse.self, from: response.data)
            } catch {
                throw SpotifyError.invalidResponse
            }
        }

        let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: response.data)
        if oauthError?.error == "invalid_grant" {
            throw SpotifyError.notConnected
        }
        let message = oauthError?.errorDescription ?? oauthError?.error ?? "Spotify authorization failed."
        throw SpotifyError.server(
            statusCode: response.statusCode,
            message: message
        )
    }

    private func sendCurrentlyPlaying(accessToken: String) async throws -> SpotifyHTTPResponse {
        let endpoint = URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> SpotifyHTTPResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let spotifyError as SpotifyError {
            throw spotifyError
        } catch {
            throw SpotifyError.network("Spotify could not be reached. Check the network connection and try again.")
        }
    }

    private func decodePlayback(data: Data) throws -> SpotifyPlaybackContent {
        let playback: SpotifyCurrentlyPlayingResponse
        do {
            playback = try JSONDecoder().decode(SpotifyCurrentlyPlayingResponse.self, from: data)
        } catch {
            throw SpotifyError.invalidResponse
        }

        if let item = playback.item {
            let playbackType = playback.currentlyPlayingType ?? item.type ?? "unknown"
            if playbackType == "track" {
                let identity = item.id ?? item.uri
                if let identity {
                    let duration = max(0, item.durationMilliseconds ?? 0)
                    let progress = min(max(0, playback.progressMilliseconds ?? 0), duration)
                    let changedAt = playback.timestamp.map { timestamp in
                        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
                    }
                    let track = SpotifyTrackPlayback(
                        id: identity,
                        title: item.name,
                        artists: item.artists?.map(\.name) ?? [],
                        albumTitle: item.album?.name ?? "",
                        durationMilliseconds: duration,
                        progressMilliseconds: progress,
                        isPlaying: playback.isPlaying,
                        playbackStateChangedAt: changedAt,
                        sampledAt: now(),
                        spotifyURL: item.externalURLs?.spotify
                    )
                    return .track(track)
                }
                throw SpotifyError.invalidResponse
            }

            return .unsupported(
                SpotifyUnsupportedPlayback(
                    type: playbackType,
                    title: item.name
                )
            )
        }

        if playback.currentlyPlayingType == "ad" {
            return .unsupported(
                SpotifyUnsupportedPlayback(
                    type: "advertisement",
                    title: nil
                )
            )
        }
        return .nothingPlaying
    }

    private func apiErrorMessage(data: Data) -> String? {
        try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message
    }

    private static func formEncodedData(values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted { firstValue, secondValue in
            firstValue.key < secondValue.key
        }.map { name, value in
            URLQueryItem(name: name, value: value)
        }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func scopes(scope: String) -> [String] {
        scope.split(separator: " ").map(String.init)
    }
}

