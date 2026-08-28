import Foundation

public enum SpotifyError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case randomGenerationFailed
    case invalidAuthorizationCallback
    case authorizationDenied(String?)
    case authorizationStateMismatch
    case notConnected
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int, message: String)
    case invalidResponse
    case tokenStorage(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            message
        case .randomGenerationFailed:
            "Spotify authorization could not create secure random values."
        case .invalidAuthorizationCallback:
            "Spotify returned an invalid authorization response."
        case .authorizationDenied(let reason):
            reason ?? "Spotify authorization was denied."
        case .authorizationStateMismatch:
            "Spotify authorization could not be verified. Please try connecting again."
        case .notConnected:
            "Connect Spotify to continue."
        case .forbidden(let message):
            message
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Spotify is limiting requests. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            } else {
                "Spotify is limiting requests. Please try again shortly."
            }
        case .server(_, let message):
            message
        case .invalidResponse:
            "Spotify returned an unexpected response."
        case .tokenStorage(let message):
            message
        case .network(let message):
            message
        }
    }
}

