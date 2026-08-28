import Foundation
import Observation
import SpotifyKit

struct SpotifyTrackDisplay: Equatable, Sendable {
    let id: String
    let title: String
    let artistText: String
    let albumText: String?
    let playbackStatusText: String
    let progressText: String
    let progressFraction: Double
    let spotifyURL: URL?

    init(track: SpotifyTrackPlayback) {
        id = track.id
        title = track.title
        if track.artists.isEmpty {
            artistText = "Unknown Artist"
        } else {
            artistText = track.artists.joined(separator: ", ")
        }
        albumText = track.albumTitle.isEmpty ? nil : track.albumTitle
        playbackStatusText = track.isPlaying ? "Playing" : "Paused"
        let duration = Self.durationText(milliseconds: track.durationMilliseconds)
        if let progressMilliseconds = track.progressMilliseconds {
            let progress = Self.durationText(milliseconds: progressMilliseconds)
            progressText = "\(progress) / \(duration)"
            if track.durationMilliseconds > 0 {
                progressFraction = Double(progressMilliseconds) / Double(track.durationMilliseconds)
            } else {
                progressFraction = 0
            }
        } else {
            progressText = "Position unavailable / \(duration)"
            progressFraction = 0
        }
        spotifyURL = track.spotifyURL
    }

    private static func durationText(milliseconds: Int) -> String {
        let totalSeconds = max(
            0,
            milliseconds / 1_000
        )
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(
            format: "%d:%02d",
            minutes,
            seconds
        )
    }
}

enum SpotifyLyricsViewState: Equatable, Sendable {
    case notConfigured(String)
    case disconnected
    case connecting
    case restoring
    case disconnecting
    case loadingPlayback
    case nothingPlaying
    case unsupported(title: String, message: String)
    case track(SpotifyTrackDisplay)
    case failed(message: String, connected: Bool)
}

@MainActor
@Observable
final class SpotifyLyricsViewModel {
    private(set) var state: SpotifyLyricsViewState

    @ObservationIgnored private let session: SpotifySession?
    @ObservationIgnored private let authorizationCoordinator: (any SpotifyAuthorizing)?
    @ObservationIgnored private(set) var workTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(
        session: SpotifySession,
        authorizationCoordinator: any SpotifyAuthorizing
    ) {
        self.session = session
        self.authorizationCoordinator = authorizationCoordinator
        state = .disconnected
    }

    init(configurationMessage: String) {
        session = nil
        authorizationCoordinator = nil
        state = .notConfigured(configurationMessage)
    }

    func start() {
        if started || session == nil {
            return
        }
        started = true
        state = .restoring
        let previousTask = workTask
        workTask = Task { [weak self] in
            await previousTask?.value
            if Task.isCancelled { return }
            await self?.restoreConnection()
        }
    }

    func connectSpotify() {
        switch state {
        case .disconnected, .failed:
            break
        default:
            return
        }
        if let authorizationCoordinator {
            workTask?.cancel()
            state = .connecting
            workTask = Task { [weak self] in
                do {
                    try await authorizationCoordinator.connect()
                    try Task.checkCancellation()
                    await self?.loadPlayback()
                } catch is CancellationError {
                    if !Task.isCancelled {
                        self?.state = .disconnected
                    }
                } catch SpotifyError.authorizationDenied("access_denied") {
                    if !Task.isCancelled {
                        self?.state = .disconnected
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.state = .failed(
                            message: Self.message(error: error),
                            connected: false
                        )
                    }
                }
            }
        }
    }

    func refreshPlayback() {
        switch state {
        case .track, .nothingPlaying, .unsupported, .failed:
            break
        default:
            return
        }
        if session != nil {
            workTask?.cancel()
            state = .loadingPlayback
            workTask = Task { [weak self] in
                await self?.loadPlayback()
            }
        }
    }

    func disconnectSpotify() {
        if state == .disconnecting { return }
        let previousTask = workTask
        previousTask?.cancel()
        state = .disconnecting
        if let session, let authorizationCoordinator {
            workTask = Task { [weak self] in
                await authorizationCoordinator.cancel()
                await previousTask?.value
                do {
                    try await session.disconnect()
                    if !Task.isCancelled {
                        self?.state = .disconnected
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.state = .failed(
                            message: Self.message(error: error),
                            connected: false
                        )
                    }
                }
            }
        }
    }

    func stop() {
        started = false
        switch state {
        case .connecting:
            disconnectSpotify()
        case .disconnecting:
            break
        default:
            workTask?.cancel()
        }
    }

    var showsDisconnect: Bool {
        switch state {
        case .track, .nothingPlaying, .unsupported, .loadingPlayback, .failed:
            true
        default:
            false
        }
    }

    private func restoreConnection() async {
        if let session {
            do {
                let restored = try await session.restoreConnection()
                try Task.checkCancellation()
                if restored {
                    await loadPlayback()
                } else {
                    state = .disconnected
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    state = .failed(
                        message: Self.message(error: error),
                        connected: false
                    )
                }
            }
        }
    }

    private func loadPlayback() async {
        if Task.isCancelled { return }
        if let session {
            state = .loadingPlayback
            do {
                let playback = try await session.currentlyPlaying()
                try Task.checkCancellation()
                switch playback {
                case .track(let track):
                    state = .track(SpotifyTrackDisplay(track: track))
                case .unsupported(let unsupported):
                    let title = unsupported.title ?? "Unsupported Spotify Content"
                    let message: String
                    switch unsupported.type {
                    case "episode":
                        message = "Podcasts and episodes do not use the song lyrics flow."
                    case "ad":
                        message = "Refresh when the next song begins."
                    default:
                        message = "This Spotify item type is not supported for lyrics."
                    }
                    state = .unsupported(
                        title: title,
                        message: message
                    )
                case .nothingPlaying:
                    state = .nothingPlaying
                }
            } catch is CancellationError {
                return
            } catch let spotifyError as SpotifyError {
                if !Task.isCancelled {
                    let connected: Bool
                    if spotifyError == .notConnected {
                        connected = false
                    } else {
                        connected = true
                    }
                    state = .failed(
                        message: Self.message(error: spotifyError),
                        connected: connected
                    )
                }
            } catch {
                if !Task.isCancelled {
                    state = .failed(
                        message: Self.message(error: error),
                        connected: true
                    )
                }
            }
        }
    }

    private static func message(error: any Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "Something went wrong. Please try again."
    }
}
