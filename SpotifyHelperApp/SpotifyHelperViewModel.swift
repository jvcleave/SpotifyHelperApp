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
    let positionNote: String
    let spotifyURL: URL?

    init(
        track: SpotifyTrackPlayback,
        estimate: SpotifyPositionEstimate?,
        isMonitoring: Bool,
        hasError: Bool
    ) {
        id = track.id
        title = track.title
        artistText = track.artists.isEmpty ? "Unknown Artist" : track.artists.joined(separator: ", ")
        albumText = track.albumTitle.isEmpty ? nil : track.albumTitle
        playbackStatusText = track.isPlaying ? "Playing at last update" : "Paused at last update"
        let duration = Double(track.durationMilliseconds) / 1_000
        let durationText = Self.durationText(seconds: duration)
        if let position = estimate?.seconds {
            progressText = "\(Self.durationText(seconds: position)) / \(durationText)"
            progressFraction = duration > 0 ? position / duration : 0
        } else {
            progressText = "Position unavailable / \(durationText)"
            progressFraction = 0
        }
        if estimate?.seconds == nil {
            positionNote = "Spotify did not report a playback position."
        } else if hasError {
            positionNote = "Position frozen — Spotify could not be refreshed."
        } else if estimate?.isStale == true {
            positionNote = "Stale position — waiting for a fresh Spotify update."
        } else if !isMonitoring {
            positionNote = "Position frozen — monitoring is stopped."
        } else if track.isPlaying {
            positionNote = "Estimated position between Spotify updates; not sample-accurate."
        } else {
            positionNote = "Position reported by Spotify; playback was paused."
        }
        spotifyURL = track.spotifyURL
    }

    private static func durationText(seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(
            0,
            seconds
        ))
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }
}

struct SpotifyMonitoringDisplay: Equatable, Sendable {
    var statusText = "Monitoring stopped"
    var lastUpdatedText = "No playback update yet"
    var warningText: String?
    var isMonitoring = false
    var isRefreshing = false
    var canRefresh = true
    var toggleTitle: String { isMonitoring ? "Stop Monitoring" : "Start Monitoring" }
}

enum SpotifyHelperViewState: Equatable, Sendable {
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
final class SpotifyHelperViewModel {
    private(set) var state: SpotifyHelperViewState
    private(set) var monitoring = SpotifyMonitoringDisplay()

    @ObservationIgnored private let session: SpotifySession?
    @ObservationIgnored private let authorizationCoordinator: (any SpotifyAuthorizing)?
    @ObservationIgnored private let monitor: SpotifyPlaybackMonitor?
    @ObservationIgnored private(set) var workTask: Task<Void, Never>?
    @ObservationIgnored private(set) var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var latestSnapshot = SpotifyPlaybackMonitorState()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var applicationActive = true
    @ObservationIgnored private var awake = true
    @ObservationIgnored private var monitoringEnabled = true

    init(
        session: SpotifySession,
        authorizationCoordinator: any SpotifyAuthorizing,
        monitor: SpotifyPlaybackMonitor
    ) {
        self.session = session
        self.authorizationCoordinator = authorizationCoordinator
        self.monitor = monitor
        state = .disconnected
    }

    init(configurationMessage: String) {
        session = nil
        authorizationCoordinator = nil
        monitor = nil
        state = .notConfigured(configurationMessage)
    }

    deinit {
        workTask?.cancel()
        monitoringTask?.cancel()
        updatesTask?.cancel()
        displayTask?.cancel()
    }

    func start() {
        if started || session == nil { return }
        started = true
        state = .restoring
        let previousTask = workTask
        workTask = Task { [weak self] in
            await previousTask?.value
            if Task.isCancelled { return }
            if let self, let session {
                do {
                    let restored = try await session.restoreConnection()
                    try Task.checkCancellation()
                    if restored {
                        await beginPlayback()
                    } else {
                        state = .disconnected
                    }
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
    }

    func connectSpotify() {
        switch state {
        case .disconnected, .failed(_, false): break
        default: return
        }
        if let authorizationCoordinator {
            workTask?.cancel()
            state = .connecting
            workTask = Task { [weak self] in
                do {
                    try await authorizationCoordinator.connect()
                    try Task.checkCancellation()
                    await self?.beginPlayback()
                } catch is CancellationError {
                    if !Task.isCancelled { self?.state = .disconnected }
                } catch SpotifyError.authorizationDenied("access_denied") {
                    if !Task.isCancelled { self?.state = .disconnected }
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
        if !showsDisconnect || !started || !applicationActive || !awake || !monitoring.canRefresh { return }
        if let monitor {
            workTask?.cancel()
            workTask = Task { [weak self] in
                await monitor.refresh()
                let snapshot = await monitor.state
                if Task.isCancelled { return }
                self?.receive(snapshot)
            }
        }
    }

    func toggleMonitoring() {
        monitoringEnabled = !monitoring.isMonitoring
        reconcileMonitoring()
    }

    func applicationActivityChanged(isActive: Bool) {
        applicationActive = isActive
        if started && showsDisconnect { reconcileMonitoring() }
    }

    func systemSleepChanged(isAwake: Bool) {
        awake = isAwake
        if started && showsDisconnect { reconcileMonitoring() }
    }

    func disconnectSpotify() {
        if state == .disconnecting { return }
        let previousTask = workTask
        previousTask?.cancel()
        state = .disconnecting
        updatesTask?.cancel()
        updatesTask = nil
        displayTask?.cancel()
        displayTask = nil
        monitoringTask?.cancel()
        let previousMonitoring = monitoringTask
        if let session, let authorizationCoordinator, let monitor {
            workTask = Task { [weak self] in
                await monitor.stop(clearPlayback: true)
                await previousMonitoring?.value
                await authorizationCoordinator.cancel()
                await previousTask?.value
                do {
                    try await session.disconnect()
                    if !Task.isCancelled {
                        self?.latestSnapshot = SpotifyPlaybackMonitorState()
                        self?.monitoring = SpotifyMonitoringDisplay()
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
        updatesTask?.cancel()
        updatesTask = nil
        displayTask?.cancel()
        displayTask = nil
        switch state {
        case .connecting: disconnectSpotify()
        case .disconnecting: break
        default:
            workTask?.cancel()
            reconcileMonitoring()
        }
    }

    var showsDisconnect: Bool {
        switch state {
        case .track, .nothingPlaying, .unsupported, .loadingPlayback: true
        case .failed(_, let connected): connected
        default: false
        }
    }

    private func beginPlayback() async {
        if Task.isCancelled { return }
        if let monitor {
            state = .loadingPlayback
            updatesTask?.cancel()
            let updates = await monitor.updates()
            if Task.isCancelled { return }
            updatesTask = Task { [weak self] in
                for await snapshot in updates {
                    if Task.isCancelled { return }
                    self?.receive(snapshot)
                }
            }
            reconcileMonitoring()
            await monitoringTask?.value
            let snapshot = await monitor.state
            if !Task.isCancelled { receive(snapshot) }
        }
    }

    /// Serializes lifecycle transitions while stop can interrupt an in-flight
    /// start/refresh. The newest transition is the only one allowed to restart.
    private func reconcileMonitoring() {
        if let monitor {
            monitoringTask?.cancel()
            let previousTask = monitoringTask
            let shouldMonitor = started && applicationActive && awake && monitoringEnabled && showsDisconnect
            monitoringTask = Task { [weak self] in
                await monitor.stop()
                await previousTask?.value
                if Task.isCancelled { return }
                if shouldMonitor { await monitor.start() }
                let snapshot = await monitor.state
                if Task.isCancelled { return }
                self?.receive(snapshot)
            }
        }
    }

    private func receive(_ snapshot: SpotifyPlaybackMonitorState) {
        if !showsDisconnect || snapshot.revision < latestSnapshot.revision { return }
        latestSnapshot = snapshot
        renderPlayback()
        if showsDisconnect && started && applicationActive && awake {
            if displayTask == nil {
                displayTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        if Task.isCancelled { return }
                        self?.renderPlayback()
                    }
                }
            }
        } else {
            displayTask?.cancel()
            displayTask = nil
        }
    }

    private func renderPlayback() {
        if !showsDisconnect { return }
        let snapshot = latestSnapshot
        var display = SpotifyMonitoringDisplay()
        display.isMonitoring = snapshot.isMonitoring
        display.isRefreshing = snapshot.isRefreshing
        let coolingDown = snapshot.retryAt.map { $0 > Date() } ?? false
        display.canRefresh = !snapshot.isRefreshing && !coolingDown
        if !applicationActive || !awake {
            display.statusText = "Monitoring suspended while the app is inactive or asleep"
        } else if snapshot.isRefreshing {
            display.statusText = "Refreshing Spotify…"
        } else if snapshot.isMonitoring {
            display.statusText = "Monitoring Spotify · polls every 10 seconds"
        }
        if let reading = snapshot.reading {
            let updateTime = reading.receivedAt.formatted(
                date: .omitted,
                time: .standard
            )
            display.lastUpdatedText = "Last update: \(updateTime)"
        }
        if let error = snapshot.error {
            display.warningText = Self.message(error: error)
            if let retryAt = snapshot.retryAt {
                let retryTime = retryAt.formatted(
                    date: .omitted,
                    time: .standard
                )
                let retryText = snapshot.isMonitoring ? "Next retry no earlier than \(retryTime)." : "Refresh available after \(retryTime)."
                display.warningText = "\(Self.message(error: error)) \(retryText)"
            }
        }
        monitoring = display
        if let reading = snapshot.reading {
            switch reading.content {
            case .track(let track):
                state = .track(SpotifyTrackDisplay(
                    track: track,
                    estimate: reading.timeline?.estimate(),
                    isMonitoring: snapshot.isMonitoring,
                    hasError: snapshot.error != nil
                ))
            case .nothingPlaying:
                state = .nothingPlaying
            case .unsupported(let content):
                state = .unsupported(
                    title: content.title ?? "Unsupported Spotify Content",
                    message: "Spotify reported \(content.type) content. This demo displays track metadata and position."
                )
            }
        } else if let error = snapshot.error {
            state = .failed(
                message: Self.message(error: error),
                connected: error != .notConnected
            )
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
