import Foundation

public protocol SpotifyPlaybackProviding: Sendable {
    func currentlyPlaying() async throws -> SpotifyPlaybackContent
}

public struct SpotifyPlaybackReading: Sendable {
    public let content: SpotifyPlaybackContent
    public let receivedAt: Date
    public internal(set) var timeline: SpotifyPlaybackTimeline?
}

public struct SpotifyPlaybackMonitorState: Sendable {
    /// Monotonically increasing within one monitor; useful when combining streams
    /// and explicit state reads without applying an older presentation update.
    public internal(set) var revision: UInt64 = 0
    public internal(set) var reading: SpotifyPlaybackReading?
    public internal(set) var isMonitoring = false
    public internal(set) var isRefreshing = false
    public internal(set) var error: SpotifyError?
    public internal(set) var retryAt: Date?

    public init() {}
}

/// One request at a time, independently of how often a consumer redraws position.
/// Construct one monitor per session and route manual refreshes through it too.
public actor SpotifyPlaybackMonitor {
    public private(set) var state = SpotifyPlaybackMonitorState()

    private let source: any SpotifyPlaybackProviding
    private let pollInterval: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let date: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var subscribers: [UUID: AsyncStream<SpotifyPlaybackMonitorState>.Continuation] = [:]
    private var pollingTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var requestID: UUID?
    private var generation = UUID()
    private var monitoringRequested = false
    private var nextPoll: ContinuousClock.Instant?
    private var retryDeadline: ContinuousClock.Instant?
    private var failureCount = 0

    public init(
        source: any SpotifyPlaybackProviding,
        pollInterval: Duration = .seconds(10)
    ) {
        self.source = source
        self.pollInterval = max(
            .seconds(1),
            pollInterval
        )
        now = { .now }
        date = { Date() }
        sleep = { try await Task.sleep(for: $0) }
    }

    init(
        source: any SpotifyPlaybackProviding,
        pollInterval: Duration = .seconds(10),
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        date: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.source = source
        self.pollInterval = max(
            .seconds(1),
            pollInterval
        )
        self.now = now
        self.date = date
        self.sleep = sleep
    }

    deinit {
        pollingTask?.cancel()
        requestTask?.cancel()
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    /// Each subscriber receives the latest state. Canceling the final subscription
    /// stops owned work; explicit stop is still recommended for feature cleanup.
    public func updates() -> AsyncStream<SpotifyPlaybackMonitorState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SpotifyPlaybackMonitorState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        return stream
    }

    /// Refreshes immediately, then polls. Repeated starts do not create new loops.
    public func start() async {
        if Task.isCancelled { return }
        monitoringRequested = true
        await cleanupTask?.value
        if Task.isCancelled || !monitoringRequested || state.isMonitoring { return }
        state.isMonitoring = true
        let run = generation
        publish()
        await refresh()
        // Once monitoring is started it belongs to this actor, not its caller.
        // A canceled waiter must not leave isMonitoring true without a loop.
        if run != generation || !state.isMonitoring { return }
        let sleep = self.sleep
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let delay = await self?.pollDelay(run: run) {
                    if delay > .zero {
                        do { try await sleep(delay) } catch { return }
                    } else {
                        await self?.refresh()
                    }
                } else {
                    return
                }
            }
        }
    }

    /// Coalesces simultaneous requests and preserves retry cooldowns even while
    /// monitoring is stopped. Cancel work with stop(), not the awaiting task.
    public func refresh() async {
        // A canceled poll must not await cleanup that is itself waiting for it.
        if Task.isCancelled { return }
        await cleanupTask?.value
        if Task.isCancelled { return }
        if let requestTask {
            await requestTask.value
            return
        }
        if let retryDeadline, now() < retryDeadline { return }
        let id = UUID()
        requestID = id
        state.isRefreshing = true
        publish()
        let task = Task { [weak self, source] in
            do {
                let content = try await source.currentlyPlaying()
                try Task.checkCancellation()
                await self?.complete(
                    id: id,
                    result: .success(content)
                )
            } catch {
                if !Task.isCancelled {
                    let failure = error as? SpotifyError ?? .network("Spotify could not be reached. Please try again.")
                    await self?.complete(
                        id: id,
                        result: .failure(failure)
                    )
                }
            }
        }
        requestTask = task
        await task.value
        if requestID == id {
            requestID = nil
            requestTask = nil
        }
    }

    /// Cancels polling and any request, freezes position, and waits for cleanup.
    /// Use clearPlayback on disconnect so the previous account's track is removed.
    public func stop(clearPlayback: Bool = false) async {
        monitoringRequested = false
        generation = UUID()
        state.isMonitoring = false
        state.isRefreshing = false
        state.reading?.timeline?.freeze(instant: now())
        if clearPlayback {
            state.reading = nil
            state.error = nil
        }
        publish()
        if let cleanupTask {
            await cleanupTask.value
            return
        }
        let poll = pollingTask
        let request = requestTask
        poll?.cancel()
        request?.cancel()
        pollingTask = nil
        requestTask = nil
        requestID = nil
        let cleanup = Task {
            await request?.value
            await poll?.value
        }
        cleanupTask = cleanup
        await cleanup.value
        cleanupTask = nil
    }

    private func pollDelay(run: UUID) -> Duration? {
        if generation != run || !state.isMonitoring { return nil }
        return max(
            .zero,
            now().duration(to: nextPoll ?? now())
        )
    }

    private func complete(
        id: UUID,
        result: Result<SpotifyPlaybackContent, SpotifyError>
    ) {
        if requestID != id { return }
        state.isRefreshing = false
        let instant = now()
        let receivedAt = date()
        switch result {
        case .success(let content):
            var timeline: SpotifyPlaybackTimeline?
            if case .track(let track) = content {
                timeline = SpotifyPlaybackTimeline(
                    track: track,
                    sampledInstant: instant,
                    maximumExtrapolation: max(
                        .seconds(30),
                        pollInterval * 2
                    )
                )
                if !state.isMonitoring { timeline?.freeze(instant: instant) }
            }
            state.reading = SpotifyPlaybackReading(
                content: content,
                receivedAt: receivedAt,
                timeline: timeline
            )
            state.error = nil
            state.retryAt = nil
            retryDeadline = nil
            failureCount = 0
            nextPoll = instant.advanced(by: pollInterval)
        case .failure(let error):
            state.error = error
            state.reading?.timeline?.freeze(instant: instant)
            failureCount = min(
                5,
                failureCount + 1
            )
            var delay = max(
                pollInterval,
                .seconds(pow(
                    2,
                    Double(failureCount)
                ))
            )
            var retryable = true
            switch error {
            case .rateLimited(let seconds):
                if let seconds, seconds.isFinite, seconds > 0 {
                    // Do not convert an unbounded remote value into Duration.
                    // An implausible deadline requires explicit recovery instead.
                    if seconds > 31_536_000 {
                        state.error = .invalidResponse
                        retryable = false
                    } else {
                        delay = max(
                            delay,
                            .seconds(seconds)
                        )
                    }
                }
            case .network, .invalidResponse:
                break
            case .server(let status, _):
                retryable = status >= 500
            default:
                retryable = false
            }
            if error == .notConnected { state.reading = nil }
            if retryable {
                retryDeadline = instant.advanced(by: delay)
                nextPoll = retryDeadline
                let components = delay.components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                state.retryAt = receivedAt.addingTimeInterval(seconds)
            } else {
                state.isMonitoring = false
                generation = UUID()
                pollingTask?.cancel()
                pollingTask = nil
                retryDeadline = nil
                state.retryAt = nil
                nextPoll = nil
            }
        }
        publish()
    }

    private func publish() {
        state.revision += 1
        for continuation in subscribers.values {
            continuation.yield(state)
        }
    }

    private func removeSubscriber(id: UUID) async {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty { await stop() }
    }
}
