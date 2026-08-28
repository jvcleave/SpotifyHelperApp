//
//  ContentView.swift
//  SpotifyHelperApp
//
//  Created by jason van cleave on 8/28/26.
//

import SwiftUI

struct ContentView: View {
    let viewModel: SpotifyLyricsViewModel

    var body: some View {
        VStack(spacing: 0) {
            AppHeaderView()
            Divider()
            Group {
                switch viewModel.state {
                case .notConfigured(let message):
                    StatusView(
                        symbol: "gear.badge.xmark",
                        title: "Spotify Sign-In Unavailable",
                        message: message,
                        actionTitle: nil,
                        action: nil
                    )
                case .disconnected:
                    StatusView(
                        symbol: "music.note.house",
                        title: "Connect Spotify",
                        message: "Connect your account to see the song currently playing in Spotify.",
                        actionTitle: "Connect Spotify",
                        action: viewModel.connectSpotify
                    )
                case .connecting:
                    VStack {
                        LoadingView(
                            title: "Connecting Spotify",
                            message: "Complete authorization in your browser."
                        )
                        Button(
                            "Cancel",
                            action: viewModel.disconnectSpotify
                        )
                    }
                case .restoring:
                    LoadingView(
                        title: "Restoring Connection",
                        message: "Checking the saved Spotify connection."
                    )
                case .disconnecting:
                    LoadingView(
                        title: "Disconnecting",
                        message: "Removing the saved Spotify connection."
                    )
                case .loadingPlayback:
                    LoadingView(
                        title: "Checking Spotify",
                        message: "Loading the current playback state."
                    )
                case .nothingPlaying:
                    StatusView(
                        symbol: "pause.circle",
                        title: "Nothing Playing",
                        message: "Start a song in Spotify, then refresh the playback state.",
                        actionTitle: "Refresh",
                        action: viewModel.refreshPlayback
                    )
                case .unsupported(let title, let message):
                    StatusView(
                        symbol: "music.note.list",
                        title: title,
                        message: message,
                        actionTitle: "Refresh",
                        action: viewModel.refreshPlayback
                    )
                case .track(let track):
                    NowPlayingView(
                        track: track,
                        refreshAction: viewModel.refreshPlayback
                    )
                case .failed(let message, let connected):
                    FailureView(
                        message: message,
                        connected: connected,
                        retryAction: viewModel.refreshPlayback,
                        connectAction: viewModel.connectSpotify
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
        }
        .frame(
            minWidth: 560,
            minHeight: 420
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .toolbar {
            if viewModel.showsDisconnect {
                Button(
                    "Disconnect",
                    action: viewModel.disconnectSpotify
                )
            }
        }
    }
}

private struct AppHeaderView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "quote.bubble.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(
                alignment: .leading,
                spacing: 2
            ) {
                Text("Spotify Lyrics")
                    .font(.headline)
                Text("Current track and playback position")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(
            .horizontal,
            22
        )
        .padding(
            .vertical,
            16
        )
        .background(.bar)
    }
}

private struct StatusView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(
                    size: 44,
                    weight: .light
                ))
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }
            if let actionTitle, let action {
                Button(
                    actionTitle,
                    action: action
                )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(32)
    }
}

private struct FailureView: View {
    let message: String
    let connected: Bool
    let retryAction: () -> Void
    let connectAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(
                    size: 44,
                    weight: .light
                ))
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                Text("Spotify Needs Attention")
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }
            HStack(spacing: 12) {
                if connected {
                    Button(
                        "Try Again",
                        action: retryAction
                    )
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(
                        "Connect Spotify",
                        action: connectAction
                    )
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(32)
    }
}

private struct LoadingView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 7) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
    }
}

private struct NowPlayingView: View {
    let track: SpotifyTrackDisplay
    let refreshAction: () -> Void

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 24
        ) {
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                Label(
                    track.playbackStatusText,
                    systemImage: "waveform"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text(track.title)
                    .font(.system(
                        .largeTitle,
                        design: .rounded,
                        weight: .bold
                    ))
                    .lineLimit(2)
                Text(track.artistText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let albumText = track.albumText {
                    Text(albumText)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                ProgressView(value: track.progressFraction)
                    .tint(.green)
                Text(track.progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Position at last refresh")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(
                    "Refresh",
                    systemImage: "arrow.clockwise",
                    action: refreshAction
                )
                    .buttonStyle(.borderedProminent)
                if let spotifyURL = track.spotifyURL {
                    Link(destination: spotifyURL) {
                        Label(
                            "Open in Spotify",
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
        .padding(36)
        .frame(maxWidth: 620)
    }
}

#Preview("Not Configured") {
    ContentView(
        viewModel: SpotifyLyricsViewModel(
            configurationMessage: "Add a Spotify Client ID to continue."
        )
    )
}
