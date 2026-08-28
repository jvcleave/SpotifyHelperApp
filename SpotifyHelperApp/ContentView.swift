//
//  ContentView.swift
//  SpotifyHelperApp
//
//  Created by jason van cleave on 8/28/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    let viewModel: SpotifyHelperViewModel

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
                        message: "Start a song in Spotify. Monitoring will pick up the next playback update.",
                        actionTitle: nil,
                        action: nil
                    )
                case .unsupported(let title, let message):
                    StatusView(
                        symbol: "music.note.list",
                        title: title,
                        message: message,
                        actionTitle: nil,
                        action: nil
                    )
                case .track(let track):
                    NowPlayingView(track: track)
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
            if viewModel.showsDisconnect {
                Divider()
                MonitoringView(
                    display: viewModel.monitoring,
                    refreshAction: viewModel.refreshPlayback,
                    toggleAction: viewModel.toggleMonitoring
                )
            }
        }
        .frame(
            minWidth: 560,
            minHeight: 520
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(
            of: scenePhase,
            initial: true
        ) { _, phase in
            viewModel.applicationActivityChanged(isActive: phase == .active)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            viewModel.systemSleepChanged(isAwake: false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            viewModel.systemSleepChanged(isAwake: true)
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
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(
                alignment: .leading,
                spacing: 2
            ) {
                Text("Spotify Helper")
                    .font(.headline)
                Text("SpotifyKit demo · current track and estimated position")
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
                Text(track.positionNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
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

private struct MonitoringView: View {
    let display: SpotifyMonitoringDisplay
    let refreshAction: () -> Void
    let toggleAction: () -> Void

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 10
        ) {
            HStack {
                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    Text(display.statusText)
                        .font(.subheadline)
                    Text(display.lastUpdatedText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if display.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let warning = display.warningText {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button(
                    display.toggleTitle,
                    action: toggleAction
                )
                Button(
                    "Refresh Now",
                    systemImage: "arrow.clockwise",
                    action: refreshAction
                )
                .disabled(!display.canRefresh)
            }
        }
        .padding(20)
        .background(.bar)
    }
}

#Preview("Not Configured") {
    ContentView(
        viewModel: SpotifyHelperViewModel(
            configurationMessage: "Add a Spotify Client ID to continue."
        )
    )
}
