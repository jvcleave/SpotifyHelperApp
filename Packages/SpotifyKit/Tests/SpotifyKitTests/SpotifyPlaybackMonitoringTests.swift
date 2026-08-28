import Foundation
import Synchronization
import Testing
@testable import SpotifyKit

@Suite(.timeLimit(.minutes(1))) struct SpotifyPlaybackMonitoringTests {
    @Test func positionUsesMonotonicTimeAndClampsAtDuration() {
        let instant = ContinuousClock.now
        let timeline = SpotifyPlaybackTimeline(
            track: monitoringTrack(progress: 95_000),
            sampledInstant: instant
        )
        #expect(timeline.estimate(instant: instant.advanced(by: .seconds(3))).seconds == 98)
        #expect(timeline.estimate(instant: instant.advanced(by: .seconds(20))).seconds == 100)
        #expect(timeline.estimate(instant: instant.advanced(by: .seconds(-5))).seconds == 95)
    }

    @Test func stalePositionStopsExtrapolatingAndFreezeIsIdempotent() {
        let instant = ContinuousClock.now
        var timeline = SpotifyPlaybackTimeline(
            track: monitoringTrack(progress: 10_000),
            sampledInstant: instant
        )
        let stale = timeline.estimate(instant: instant.advanced(by: .seconds(60)))
        #expect(stale.seconds == 40)
        #expect(stale.isStale)
        timeline.freeze(instant: instant.advanced(by: .seconds(2)))
        timeline.freeze(instant: instant.advanced(by: .seconds(8)))
        #expect(timeline.estimate(instant: instant.advanced(by: .seconds(20))).seconds == 12)
    }

    @Test func pausedMissingAndInvalidPositionsStayHonest() {
        let instant = ContinuousClock.now
        let paused = SpotifyPlaybackTimeline(
            track: monitoringTrack(
                progress: 12_000,
                isPlaying: false
            ),
            sampledInstant: instant
        )
        #expect(paused.estimate(instant: instant.advanced(by: .seconds(10))).seconds == 12)
        let missing = SpotifyPlaybackTimeline(track: monitoringTrack(progress: nil))
        #expect(missing.estimate().seconds == nil)
        let invalid = SpotifyPlaybackTimeline(
            track: monitoringTrack(progress: -1_000),
            sampledInstant: instant
        )
        #expect(invalid.estimate(instant: instant).seconds == 0)
    }

    @Test func newSnapshotsReplaceTrackSeekPauseAndEmptyState() async {
        let clock = MonitoringClock()
        let source = PlaybackQueue(results: [
            .success(.track(monitoringTrack(progress: 30_000))),
            .success(.track(monitoringTrack(
                progress: 5_000,
                isPlaying: false
            ))),
            .success(.track(monitoringTrack(
                progress: 0,
                id: "next-song"
            ))),
            .success(.nothingPlaying)
        ])
        let monitor = makeMonitor(
            source: source,
            clock: clock
        )
        await monitor.start()
        clock.advance(.seconds(3))
        #expect(await monitor.state.reading?.timeline?.estimate(instant: clock.now()).seconds == 33)
        await monitor.refresh()
        clock.advance(.seconds(2))
        #expect(await monitor.state.reading?.timeline?.estimate(instant: clock.now()).seconds == 5)
        await monitor.refresh()
        #expect(await monitor.state.reading?.content == .track(monitoringTrack(
            progress: 0,
            id: "next-song"
        )))
        await monitor.refresh()
        #expect(await monitor.state.reading?.content == .nothingPlaying)
        #expect(await monitor.state.reading?.timeline == nil)
        await monitor.stop(clearPlayback: true)
        #expect(await monitor.state.reading == nil)
    }

    @Test func rateLimitCooldownSurvivesManualRefreshAndRestart() async {
        let clock = MonitoringClock()
        let source = PlaybackQueue(results: [
            .failure(.rateLimited(retryAfter: 60)),
            .success(.nothingPlaying)
        ])
        let monitor = makeMonitor(
            source: source,
            clock: clock
        )
        await monitor.start()
        #expect(await monitor.state.retryAt == clock.date().addingTimeInterval(60))
        await monitor.refresh()
        await monitor.stop()
        await monitor.start()
        #expect(await source.calls == 1)
        clock.advance(.seconds(60))
        await monitor.refresh()
        #expect(await source.calls == 2)
        #expect(await monitor.state.error == nil)
        #expect(await monitor.state.retryAt == nil)
        await monitor.stop()
    }

    @Test func networkFailureFreezesReadingAndRecoveryReanchorsIt() async {
        let clock = MonitoringClock()
        let source = PlaybackQueue(results: [
            .success(.track(monitoringTrack(progress: 10_000))),
            .failure(.network("Offline")),
            .success(.track(monitoringTrack(progress: 50_000)))
        ])
        let monitor = makeMonitor(
            source: source,
            clock: clock
        )
        await monitor.start()
        clock.advance(.seconds(3))
        await monitor.refresh()
        clock.advance(.seconds(12))
        #expect(await monitor.state.isMonitoring)
        #expect(await monitor.state.error == .network("Offline"))
        #expect(await monitor.state.reading?.timeline?.estimate(instant: clock.now()).seconds == 13)
        await monitor.refresh()
        #expect(await monitor.state.error == nil)
        #expect(await monitor.state.reading?.timeline?.estimate(instant: clock.now()).seconds == 50)
        await monitor.stop()
    }

    @Test func revokedConnectionClearsReadingAndStopsPolling() async {
        let source = PlaybackQueue(results: [
            .success(.track(monitoringTrack(progress: 10_000))),
            .failure(.notConnected)
        ])
        let monitor = SpotifyPlaybackMonitor(source: source)
        await monitor.start()
        await monitor.refresh()
        #expect(await monitor.state.reading == nil)
        #expect(await monitor.state.error == .notConnected)
        #expect(await monitor.state.isMonitoring == false)
        #expect(await monitor.state.retryAt == nil)
        await monitor.stop()
    }

    @Test func repeatedStartsAndConcurrentRefreshesShareOneRequest() async {
        let source = SuspendedPlayback()
        let monitor = SpotifyPlaybackMonitor(source: source)
        let first = Task { await monitor.start() }
        await source.waitUntilStarted()
        await monitor.start()
        let second = Task { await monitor.refresh() }
        await monitor.stop(clearPlayback: true)
        await first.value
        second.cancel()
        // A second stop also cancels a refresh that raced with the first cleanup.
        await monitor.stop(clearPlayback: true)
        await second.value
        #expect(await source.maximumConcurrentCalls == 1)
        #expect(await monitor.state.reading == nil)
        #expect(await monitor.state.isMonitoring == false)
        #expect(await monitor.state.isRefreshing == false)
    }

    @Test func pollingRefreshesAfterItsDelayAndStopsCleanly() async {
        let clock = MonitoringClock()
        let sleeper = MonitoringSleeper()
        let source = PlaybackQueue(results: [
            .success(.track(monitoringTrack(progress: 0))),
            .success(.nothingPlaying)
        ])
        let monitor = SpotifyPlaybackMonitor(
            source: source,
            now: { clock.now() },
            date: { clock.date() },
            sleep: { try await sleeper.sleep($0) }
        )
        let stream = await monitor.updates()
        await monitor.start()
        #expect(await sleeper.waitUntilSleeping() == .seconds(10))
        await monitor.start()
        #expect(await source.calls == 1)
        clock.advance(.seconds(10))
        await sleeper.resume()
        for await state in stream {
            if state.reading?.content == .nothingPlaying { break }
        }
        #expect(await source.calls == 2)
        await monitor.stop()
        #expect(await monitor.state.isMonitoring == false)
    }

    private func makeMonitor(
        source: any SpotifyPlaybackProviding,
        clock: MonitoringClock
    ) -> SpotifyPlaybackMonitor {
        SpotifyPlaybackMonitor(
            source: source,
            now: { clock.now() },
            date: { clock.date() },
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
    }

    @Test func cancelledRequestCannotPublishALateResponse() async {
        let source = DelayedPlayback()
        let monitor = SpotifyPlaybackMonitor(source: source)
        let stream = await monitor.updates()
        let start = Task { await monitor.start() }
        await source.waitUntilStarted()
        let stop = Task { await monitor.stop(clearPlayback: true) }
        for await snapshot in stream {
            if !snapshot.isMonitoring && !snapshot.isRefreshing { break }
        }
        await source.finish()
        await stop.value
        await start.value
        #expect(await monitor.state.reading == nil)
        #expect(await monitor.state.error == nil)
        #expect(await monitor.state.isMonitoring == false)
    }

    @Test func cancellingFinalSubscriberStopsPolling() async {
        let source = PlaybackQueue(results: [.success(.nothingPlaying)])
        let sleeper = MonitoringSleeper()
        let monitor = SpotifyPlaybackMonitor(
            source: source,
            now: { .now },
            date: { Date() },
            sleep: { try await sleeper.sleep($0) }
        )
        let updates = await monitor.updates()
        let observer = Task {
            for await _ in updates {
                if Task.isCancelled { return }
            }
        }
        await monitor.start()
        _ = await sleeper.waitUntilSleeping()
        observer.cancel()
        await observer.value
        await sleeper.waitUntilCancelled()
        #expect(await monitor.state.isMonitoring == false)
        await monitor.stop()
    }

    @Test func cancelledStartWaiterDoesNotOrphanOwnedMonitoring() async {
        let source = DelayedPlayback()
        let sleeper = MonitoringSleeper()
        let monitor = SpotifyPlaybackMonitor(
            source: source,
            now: { .now },
            date: { Date() },
            sleep: { try await sleeper.sleep($0) }
        )
        let start = Task { await monitor.start() }
        await source.waitUntilStarted()
        start.cancel()
        await source.finish()
        await start.value
        _ = await sleeper.waitUntilSleeping()
        #expect(await monitor.state.isMonitoring)
        await monitor.stop()
        #expect(await monitor.state.isMonitoring == false)
    }

    @Test func unrepresentableRetryDelayStopsWithoutCrashing() async {
        let source = PlaybackQueue(results: [.failure(.rateLimited(retryAfter: .greatestFiniteMagnitude))])
        let monitor = SpotifyPlaybackMonitor(source: source)
        await monitor.start()
        #expect(await monitor.state.error == .invalidResponse)
        #expect(await monitor.state.isMonitoring == false)
        await monitor.stop()
    }
}

private func monitoringTrack(
    progress: Int?,
    isPlaying: Bool = true,
    id: String = "song"
) -> SpotifyTrackPlayback {
    SpotifyTrackPlayback(
        id: id,
        title: "Test Song",
        artists: ["Test Artist"],
        albumTitle: "Test Album",
        durationMilliseconds: 100_000,
        progressMilliseconds: progress,
        isPlaying: isPlaying,
        playbackStateChangedAt: .distantPast,
        sampledAt: .distantPast,
        spotifyURL: nil
    )
}

private final class MonitoringClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    private let origin = Date(timeIntervalSince1970: 1_000)
    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func date() -> Date { origin }
    func advance(_ duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

private actor PlaybackQueue: SpotifyPlaybackProviding {
    var results: [Result<SpotifyPlaybackContent, SpotifyError>]
    private(set) var calls = 0
    init(results: [Result<SpotifyPlaybackContent, SpotifyError>]) {
        self.results = results
    }
    func currentlyPlaying() throws -> SpotifyPlaybackContent {
        calls += 1
        if results.isEmpty { throw SpotifyError.network("No fixture") }
        return try results.removeFirst().get()
    }
}

private actor SuspendedPlayback: SpotifyPlaybackProviding {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var calls = 0
    private var concurrentCalls = 0
    private(set) var maximumConcurrentCalls = 0
    func currentlyPlaying() async throws -> SpotifyPlaybackContent {
        calls += 1
        concurrentCalls += 1
        maximumConcurrentCalls = max(
            concurrentCalls,
            maximumConcurrentCalls
        )
        defer { concurrentCalls -= 1 }
        startedWaiter?.resume()
        startedWaiter = nil
        try await Task.sleep(for: .seconds(3_600))
        return .nothingPlaying
    }
    func waitUntilStarted() async {
        if calls == 0 {
            await withCheckedContinuation { startedWaiter = $0 }
        }
    }
}

private actor MonitoringSleeper {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var waiting: CheckedContinuation<Duration, Never>?
    private var duration: Duration?
    private var cancelled = false
    private var cancellationWaiter: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.duration = duration
                waiting?.resume(returning: duration)
                waiting = nil
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func waitUntilSleeping() async -> Duration {
        if let duration { return duration }
        return await withCheckedContinuation { waiting = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
        duration = nil
    }
    func waitUntilCancelled() async {
        if !cancelled {
            await withCheckedContinuation { cancellationWaiter = $0 }
        }
    }
    private func cancel() {
        cancelled = true
        cancellationWaiter?.resume()
        cancellationWaiter = nil
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        duration = nil
    }
}

private actor DelayedPlayback: SpotifyPlaybackProviding {
    private var continuation: CheckedContinuation<SpotifyPlaybackContent, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    func currentlyPlaying() async -> SpotifyPlaybackContent {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if continuation == nil {
            await withCheckedContinuation { startedWaiter = $0 }
        }
    }
    func finish() {
        continuation?.resume(returning: .track(monitoringTrack(progress: 0)))
        continuation = nil
    }
}
