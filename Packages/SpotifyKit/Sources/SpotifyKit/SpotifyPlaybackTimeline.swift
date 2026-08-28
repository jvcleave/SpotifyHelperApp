import Foundation

public struct SpotifyPositionEstimate: Equatable, Sendable {
    public let seconds: TimeInterval?
    public let isStale: Bool
}

/// Estimates position using elapsed monotonic time, never Spotify's last-change
/// timestamp or the wall clock. A new response creates a new timeline.
public struct SpotifyPlaybackTimeline: Sendable {
    private let progress: TimeInterval?
    private let duration: TimeInterval
    private let isPlaying: Bool
    private let sampledInstant: ContinuousClock.Instant
    private let maximumExtrapolation: Duration
    private var frozenInstant: ContinuousClock.Instant?

    public init(
        track: SpotifyTrackPlayback,
        sampledInstant: ContinuousClock.Instant = .now,
        maximumExtrapolation: Duration = .seconds(30)
    ) {
        duration = max(
            0,
            Double(track.durationMilliseconds) / 1000
        )
        if let milliseconds = track.progressMilliseconds {
            progress = min(
                duration,
                max(
                    0,
                    Double(milliseconds) / 1000
                )
            )
        } else {
            progress = nil
        }
        isPlaying = track.isPlaying
        self.sampledInstant = sampledInstant
        self.maximumExtrapolation = max(
            .zero,
            maximumExtrapolation
        )
    }

    public mutating func freeze(instant: ContinuousClock.Instant = .now) {
        if frozenInstant == nil {
            frozenInstant = instant
        }
    }

    public func estimate(instant: ContinuousClock.Instant = .now) -> SpotifyPositionEstimate {
        let elapsed = max(
            .zero,
            sampledInstant.duration(to: instant)
        )
        let cutoff = min(
            instant,
            frozenInstant ?? instant
        )
        let advancingDuration = min(
            maximumExtrapolation,
            max(
                .zero,
                sampledInstant.duration(to: cutoff)
            )
        )
        let components = advancingDuration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let position = progress.map { progress in
            min(
                duration,
                progress + (isPlaying ? seconds : 0)
            )
        }
        return SpotifyPositionEstimate(
            seconds: position,
            isStale: elapsed > maximumExtrapolation
        )
    }
}
