//
//  SpotifyHelperAppApp.swift
//  SpotifyHelperApp
//
//  Created by jason van cleave on 8/28/26.
//

import SpotifyKit
import SwiftUI

@main
struct SpotifyHelperAppApp: App {
    @State private var viewModel: SpotifyLyricsViewModel

    init() {
        let viewModel: SpotifyLyricsViewModel
        do {
            let configuration = try SpotifyAppConfiguration.load()
            let session = SpotifySession(configuration: configuration)
            let authorizationCoordinator = SpotifyAuthorizationCoordinator(session: session)
            viewModel = SpotifyLyricsViewModel(
                session: session,
                authorizationCoordinator: authorizationCoordinator
            )
        } catch {
            let message: String
            if let localizedError = error as? LocalizedError,
               let errorDescription = localizedError.errorDescription {
                message = errorDescription
            } else {
                message = "Spotify is not configured."
            }
            viewModel = SpotifyLyricsViewModel(configurationMessage: message)
        }
        _viewModel = State(initialValue: viewModel)
    }

    var body: some Scene {
        Window(
            "Spotify Lyrics",
            id: "spotify-lyrics"
        ) {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(
            width: 680,
            height: 520
        )
    }
}
