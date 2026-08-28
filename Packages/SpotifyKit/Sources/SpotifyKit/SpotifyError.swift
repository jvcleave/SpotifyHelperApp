import Foundation

public enum SpotifyError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case randomGenerationFailed
    case invalidAuthorizationCallback
    case authorizationDenied(String?)
    case authorizationStateMismatch
    case authorizationInProgress
    case callbackPortUnavailable(UInt16)
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
            if reason == "access_denied" {
                "Spotify connection was cancelled."
            } else {
                reason ?? "Spotify authorization was denied."
            }
        case .authorizationStateMismatch:
            "Spotify authorization could not be verified. Please try connecting again."
        case .authorizationInProgress:
            "A Spotify connection request is already active."
        case .callbackPortUnavailable(let port):
            "Spotify sign-in needs local port \(port), but it is already in use. Close the other app or sign-in attempt using that port, then try again."
        case .notConnected:
            "Connect Spotify to continue."
        case .forbidden(let message):
            message
        case .rateLimited(let retryAfter):
            if let retryAfter {
                String(
                    format: "Spotify is limiting requests. Try again in %.0f seconds.",
                    retryAfter.rounded(.up)
                )
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
