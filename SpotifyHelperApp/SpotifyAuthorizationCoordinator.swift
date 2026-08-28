import AppKit
import Foundation
import SpotifyKit

protocol SpotifyAuthorizing: Sendable {
    func connect() async throws
    func cancel() async
}

actor SpotifyAuthorizationCoordinator: SpotifyAuthorizing {
    private let authorization: SpotifyAuthorization
    private let session: SpotifySession
    private var activeServer: SpotifyLoopbackCallbackServer?
    private var connectionInProgress = false

    init(
        authorization: SpotifyAuthorization,
        session: SpotifySession
    ) {
        self.authorization = authorization
        self.session = session
    }

    func connect() async throws {
        try Task.checkCancellation()
        if connectionInProgress {
            throw SpotifyError.invalidConfiguration("A Spotify connection request is already active.")
        }

        connectionInProgress = true
        defer {
            connectionInProgress = false
            activeServer = nil
        }

        let server = SpotifyLoopbackCallbackServer()
        activeServer = server

        do {
            let redirectURI = try await server.start()
            try Task.checkCancellation()
            let request = try authorization.makeRequest(redirectURI: redirectURI)
            let browserOpened = await MainActor.run {
                NSWorkspace.shared.open(request.authorizationURL)
            }
            if !browserOpened {
                throw SpotifyError.network("The Spotify authorization page could not be opened.")
            }

            let callbackURL = try await server.waitForCallback()
            let code = try authorization.authorizationCode(
                callbackURL: callbackURL,
                request: request
            )
            try Task.checkCancellation()
            try await session.authorize(
                code: code,
                codeVerifier: request.codeVerifier,
                redirectURI: request.redirectURI
            )
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func cancel() async {
        if let activeServer {
            await activeServer.stop()
        }
    }

}
