import CryptoKit
import Foundation
import Security

public struct SpotifyAuthorizationRequest: Equatable, Sendable {
    public let authorizationURL: URL
    public let redirectURI: URL
    public let state: String
    public let codeVerifier: String

    public init(
        authorizationURL: URL,
        redirectURI: URL,
        state: String,
        codeVerifier: String
    ) {
        self.authorizationURL = authorizationURL
        self.redirectURI = redirectURI
        self.state = state
        self.codeVerifier = codeVerifier
    }
}

public struct SpotifyAuthorization: Sendable {
    private let configuration: SpotifyConfiguration

    public init(configuration: SpotifyConfiguration) {
        self.configuration = configuration
    }

    public func makeRequest(redirectURI: URL) throws -> SpotifyAuthorizationRequest {
        if configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SpotifyError.invalidConfiguration("Add the Spotify Client ID in the app's build settings.")
        }

        let codeVerifier = try Self.secureRandomString(byteCount: 64)
        let state = try Self.secureRandomString(byteCount: 32)
        return try makeRequest(
            redirectURI: redirectURI,
            codeVerifier: codeVerifier,
            state: state
        )
    }

    func makeRequest(
        redirectURI: URL,
        codeVerifier: String,
        state: String
    ) throws -> SpotifyAuthorizationRequest {
        if configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SpotifyError.invalidConfiguration("Add the Spotify Client ID before connecting.")
        }
        let verifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if codeVerifier.count < 43 || codeVerifier.count > 128
            || codeVerifier.rangeOfCharacter(from: verifierCharacters.inverted) != nil {
            throw SpotifyError.invalidConfiguration("The PKCE verifier must contain 43 through 128 characters.")
        }
        if redirectURI.scheme != "http" || redirectURI.host != "127.0.0.1"
            || redirectURI.port == nil || redirectURI.path != configuration.redirectPath
            || redirectURI.user != nil || redirectURI.password != nil
            || redirectURI.query != nil || redirectURI.fragment != nil {
            throw SpotifyError.invalidConfiguration("Use the registered loopback callback path and a bound port.")
        }
        if state.isEmpty {
            throw SpotifyError.invalidConfiguration("The authorization state must not be empty.")
        }
        if let redirectPort = configuration.redirectPort,
           redirectPort == 0 || redirectURI.port != Int(redirectPort) {
            throw SpotifyError.invalidConfiguration("The callback port must match the registered Spotify redirect port.")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.spotify.com"
        components.path = "/authorize"
        components.queryItems = [
            URLQueryItem(
                name: "client_id",
                value: configuration.clientID
            ),
            URLQueryItem(
                name: "response_type",
                value: "code"
            ),
            URLQueryItem(
                name: "redirect_uri",
                value: redirectURI.absoluteString
            ),
            URLQueryItem(
                name: "scope",
                value: configuration.scopes.joined(separator: " ")
            ),
            URLQueryItem(
                name: "code_challenge_method",
                value: "S256"
            ),
            URLQueryItem(
                name: "code_challenge",
                value: Self.codeChallenge(codeVerifier: codeVerifier)
            ),
            URLQueryItem(
                name: "state",
                value: state
            )
        ]

        if let authorizationURL = components.url {
            return SpotifyAuthorizationRequest(
                authorizationURL: authorizationURL,
                redirectURI: redirectURI,
                state: state,
                codeVerifier: codeVerifier
            )
        }
        throw SpotifyError.invalidConfiguration("Spotify's authorization URL could not be created.")
    }

    public func authorizationCode(
        callbackURL: URL,
        request: SpotifyAuthorizationRequest
    ) throws -> String {
        if !Self.matchesRedirect(
            callbackURL: callbackURL,
            redirectURI: request.redirectURI
        ) || callbackURL.user != nil || callbackURL.password != nil || callbackURL.fragment != nil {
            throw SpotifyError.invalidAuthorizationCallback
        }

        if let components = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ) {
            let queryItems = components.queryItems ?? []
            for parameterName in ["state", "code", "error"] {
                if queryItems.filter({ $0.name == parameterName }).count > 1 {
                    throw SpotifyError.invalidAuthorizationCallback
                }
            }
            let returnedState = queryItems.first { queryItem in
                queryItem.name == "state"
            }?.value

            if returnedState != request.state {
                throw SpotifyError.authorizationStateMismatch
            }

            let error = queryItems.first { queryItem in
                queryItem.name == "error"
            }?.value
            if let error {
                throw SpotifyError.authorizationDenied(error)
            }

            let code = queryItems.first { queryItem in
                queryItem.name == "code"
            }?.value
            if let code, !code.isEmpty {
                return code
            }
        }
        throw SpotifyError.invalidAuthorizationCallback
    }

    public static func codeChallenge(codeVerifier: String) -> String {
        let verifierData = Data(codeVerifier.utf8)
        let digest = SHA256.hash(data: verifierData)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(
                of: "+",
                with: "-"
            )
            .replacingOccurrences(
                of: "/",
                with: "_"
            )
            .replacingOccurrences(
                of: "=",
                with: ""
            )
    }

    private static func secureRandomString(byteCount: Int) throws -> String {
        var bytes = [UInt8](
            repeating: 0,
            count: byteCount
        )
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )
        if status != errSecSuccess {
            throw SpotifyError.randomGenerationFailed
        }

        return Data(bytes).base64EncodedString()
            .replacingOccurrences(
                of: "+",
                with: "-"
            )
            .replacingOccurrences(
                of: "/",
                with: "_"
            )
            .replacingOccurrences(
                of: "=",
                with: ""
            )
    }

    private static func matchesRedirect(
        callbackURL: URL,
        redirectURI: URL
    ) -> Bool {
        callbackURL.scheme == redirectURI.scheme
            && callbackURL.host == redirectURI.host
            && callbackURL.port == redirectURI.port
            && callbackURL.path == redirectURI.path
    }
}
