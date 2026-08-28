import AppKit
import Foundation

/// Opens authorization in the user's browser. Inject an implementation for tests
/// or a different macOS browser integration. Implementations must honor cancellation.
public protocol SpotifyBrowserOpening: Sendable {
    func open(_ authorizationURL: URL) async throws
}

public struct SystemSpotifyBrowser: SpotifyBrowserOpening {
    public init() {}

    public func open(_ authorizationURL: URL) async throws {
        try Task.checkCancellation()
        let opened = try await MainActor.run {
            try Task.checkCancellation()
            return NSWorkspace.shared.open(authorizationURL)
        }
        try Task.checkCancellation()
        if !opened {
            throw SpotifyError.network("The Spotify authorization page could not be opened.")
        }
    }
}
