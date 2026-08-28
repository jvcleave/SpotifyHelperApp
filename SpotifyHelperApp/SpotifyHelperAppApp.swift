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
    @State private var viewModel: SpotifyHelperViewModel

    init() {
        let viewModel: SpotifyHelperViewModel
        do {
            let configuration = try SpotifyAppConfiguration.load()
            let session = SpotifySession(configuration: configuration)
            let authorizationCoordinator = SpotifyAuthorizationCoordinator(session: session)
            let monitor = SpotifyPlaybackMonitor(source: session)
            viewModel = SpotifyHelperViewModel(
                session: session,
                authorizationCoordinator: authorizationCoordinator,
                monitor: monitor
            )
        } catch {
            let message: String
            if let localizedError = error as? LocalizedError,
               let errorDescription = localizedError.errorDescription {
                message = errorDescription
            } else {
                message = "Spotify is not configured."
            }
            viewModel = SpotifyHelperViewModel(configurationMessage: message)
        }
        _viewModel = State(initialValue: viewModel)
    }

    var body: some Scene {
        Window(
            "Spotify Helper",
            id: "spotify-helper"
        ) {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(
            width: 680,
            height: 620
        )
    }
}
