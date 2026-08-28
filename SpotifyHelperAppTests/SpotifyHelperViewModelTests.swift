import Foundation
import SpotifyKit
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SpotifyHelperViewModelTests {
    private func makeViewModel(
        statusCode: Int,
        body: String,
        authorization: any SpotifyAuthorizing = StubAuthorization()
    ) -> (SpotifyHelperViewModel, TestTokenStore) {
        let store = TestTokenStore()
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "test-client"),
            transport: TestTransport(
                statusCode: statusCode,
                body: body
            ),
            tokenStore: store
        )
        return (
            SpotifyHelperViewModel(
                session: session,
                authorizationCoordinator: authorization,
                monitor: SpotifyPlaybackMonitor(source: session)
            ),
            store
        )
    }

    @Test func restorationShowsEmptyPlaybackAndAllowsDisconnect() async {
        let (viewModel, store) = makeViewModel(
            statusCode: 204,
            body: ""
        )
        viewModel.start()
        #expect(viewModel.state == .restoring)
        await viewModel.workTask?.value
        #expect(viewModel.state == .nothingPlaying)
        #expect(viewModel.showsDisconnect)
        viewModel.disconnectSpotify()
        #expect(viewModel.state == .disconnecting)
        await viewModel.workTask?.value
        #expect(viewModel.state == .disconnected)
        #expect(await store.load() == nil)
    }

    @Test func trackDisplayContainsFormattedValues() async {
        let (viewModel, _) = makeViewModel(
            statusCode: 200,
            body: """
            {"is_playing":true,"currently_playing_type":"track","progress_ms":63125,
             "item":{"id":"song","name":"Test Song","artists":[{"name":"Artist"}],
                     "album":{"name":"Album"},"duration_ms":201000}}
            """
        )
        viewModel.start()
        await viewModel.workTask?.value
        if case .track(let display) = viewModel.state {
            #expect(display.title == "Test Song")
            #expect(display.artistText == "Artist")
            #expect(display.albumText == "Album")
            #expect(display.progressText == "1:03 / 3:21")
            #expect(display.playbackStatusText == "Playing at last update")
        } else {
            Issue.record("Expected the track display")
        }
        #expect(viewModel.monitoring.isMonitoring)
        await stop(viewModel)
    }

    @Test func missingPositionIsVisible() async {
        let (viewModel, _) = makeViewModel(
            statusCode: 200,
            body: """
            {"is_playing":false,"currently_playing_type":"track","progress_ms":null,
             "item":{"id":"song","name":"Test Song","duration_ms":120000}}
            """
        )
        viewModel.start()
        await viewModel.workTask?.value
        if case .track(let display) = viewModel.state {
            #expect(display.progressText == "Position unavailable / 2:00")
            #expect(display.playbackStatusText == "Paused at last update")
        } else {
            Issue.record("Expected a paused track")
        }
        await stop(viewModel)
    }

    @Test func denialReturnsToDisconnectedState() async {
        let (viewModel, _) = makeViewModel(
            statusCode: 204,
            body: "",
            authorization: StubAuthorization(error: .authorizationDenied("access_denied"))
        )
        viewModel.connectSpotify()
        await viewModel.workTask?.value
        #expect(viewModel.state == .disconnected)
    }

    @Test func requestFailureKeepsRetryAndDisconnectAvailable() async {
        let (viewModel, _) = makeViewModel(
            statusCode: 403,
            body: #"{"error":{"message":"Account not allowlisted"}}"#
        )
        viewModel.start()
        await viewModel.workTask?.value
        #expect(viewModel.state == .failed(
            message: "Account not allowlisted",
            connected: true
        ))
        #expect(viewModel.showsDisconnect)
        #expect(!viewModel.monitoring.isMonitoring)
        await stop(viewModel)
    }

    @Test func cancelAuthorizationWaitsForCleanupBeforeReconnect() async {
        let authorization = SuspendedAuthorization()
        let (viewModel, store) = makeViewModel(
            statusCode: 204,
            body: "",
            authorization: authorization
        )
        viewModel.connectSpotify()
        await authorization.waitUntilStarted()
        viewModel.disconnectSpotify()
        #expect(viewModel.state == .disconnecting)
        viewModel.connectSpotify()
        #expect(viewModel.state == .disconnecting)
        await viewModel.workTask?.value
        #expect(viewModel.state == .disconnected)
        #expect(await store.load() == nil)
    }

    @Test func unconfiguredPreviewDoesNotStartWork() {
        let viewModel = SpotifyHelperViewModel(configurationMessage: "Client ID is missing")
        viewModel.start()
        #expect(viewModel.workTask == nil)
        #expect(viewModel.state == .notConfigured("Client ID is missing"))
    }

    @Test func manualStopSurvivesInactiveWakeAndCanRestart() async {
        let (viewModel, _) = makeViewModel(
            statusCode: 204,
            body: ""
        )
        viewModel.start()
        await viewModel.workTask?.value
        #expect(viewModel.monitoring.isMonitoring)
        viewModel.toggleMonitoring()
        await viewModel.monitoringTask?.value
        #expect(!viewModel.monitoring.isMonitoring)
        viewModel.applicationActivityChanged(isActive: false)
        viewModel.applicationActivityChanged(isActive: true)
        viewModel.systemSleepChanged(isAwake: false)
        viewModel.systemSleepChanged(isAwake: true)
        await viewModel.monitoringTask?.value
        #expect(!viewModel.monitoring.isMonitoring)
        viewModel.refreshPlayback()
        await viewModel.workTask?.value
        #expect(!viewModel.monitoring.isMonitoring)
        viewModel.toggleMonitoring()
        await viewModel.monitoringTask?.value
        #expect(viewModel.monitoring.isMonitoring)
        await stop(viewModel)
    }

    @Test func inactiveAndSleepSuspendAutomaticMonitoring() async {
        let (viewModel, _) = makeViewModel(
            statusCode: 204,
            body: ""
        )
        viewModel.start()
        await viewModel.workTask?.value
        viewModel.applicationActivityChanged(isActive: false)
        await viewModel.monitoringTask?.value
        #expect(!viewModel.monitoring.isMonitoring)
        viewModel.applicationActivityChanged(isActive: true)
        await viewModel.monitoringTask?.value
        #expect(viewModel.monitoring.isMonitoring)
        viewModel.systemSleepChanged(isAwake: false)
        await viewModel.monitoringTask?.value
        #expect(!viewModel.monitoring.isMonitoring)
        viewModel.systemSleepChanged(isAwake: true)
        await viewModel.monitoringTask?.value
        #expect(viewModel.monitoring.isMonitoring)
        await stop(viewModel)
        #expect(!viewModel.monitoring.isMonitoring)
        viewModel.start()
        await viewModel.workTask?.value
        #expect(viewModel.monitoring.isMonitoring)
        await stop(viewModel)
    }

    @Test func refreshFailureKeepsTrackAndDisconnectClearsIt() async {
        let source = AppPlaybackSource()
        let session = SpotifySession(
            configuration: SpotifyConfiguration(clientID: "test-client"),
            transport: TestTransport(
                statusCode: 204,
                body: ""
            ),
            tokenStore: TestTokenStore()
        )
        let monitor = SpotifyPlaybackMonitor(source: source)
        let viewModel = SpotifyHelperViewModel(
            session: session,
            authorizationCoordinator: StubAuthorization(),
            monitor: monitor
        )
        viewModel.start()
        await viewModel.workTask?.value
        viewModel.refreshPlayback()
        await viewModel.workTask?.value
        if case .track(let track) = viewModel.state {
            #expect(track.title == "Retained Track")
            #expect(track.positionNote.contains("frozen"))
        } else {
            Issue.record("A temporary failure must preserve the last known track")
        }
        #expect(viewModel.monitoring.warningText?.contains("Offline") == true)
        #expect(!viewModel.monitoring.canRefresh)
        viewModel.disconnectSpotify()
        await viewModel.workTask?.value
        #expect(viewModel.state == .disconnected)
        #expect(await monitor.state.reading == nil)
        #expect(!viewModel.monitoring.isMonitoring)
        await stop(viewModel)
    }

    @Test func rapidLifecycleChangesCannotRestartAfterWindowCloses() async {
        let (viewModel, _) = makeViewModel(
            statusCode: 204,
            body: ""
        )
        viewModel.start()
        await viewModel.workTask?.value
        for _ in 0..<10 {
            viewModel.applicationActivityChanged(isActive: false)
            viewModel.applicationActivityChanged(isActive: true)
        }
        await stop(viewModel)
        #expect(!viewModel.monitoring.isMonitoring)
    }

    private func stop(_ viewModel: SpotifyHelperViewModel) async {
        viewModel.stop()
        await viewModel.workTask?.value
        await viewModel.monitoringTask?.value
    }
}

private actor AppPlaybackSource: SpotifyPlaybackProviding {
    private var calls = 0
    func currentlyPlaying() throws -> SpotifyPlaybackContent {
        calls += 1
        if calls > 1 { throw SpotifyError.network("Offline") }
        return .track(SpotifyTrackPlayback(
            id: "track",
            title: "Retained Track",
            artists: ["Artist"],
            albumTitle: "Album",
            durationMilliseconds: 120_000,
            progressMilliseconds: 10_000,
            isPlaying: true,
            playbackStateChangedAt: nil,
            sampledAt: Date(),
            spotifyURL: nil
        ))
    }
}

private struct StubAuthorization: SpotifyAuthorizing {
    var error: SpotifyError? = nil
    func connect() async throws {
        if let error { throw error }
    }
    func cancel() async {}
}

private struct TestTransport: SpotifyHTTPTransport {
    let statusCode: Int
    let body: String

    func send(_ request: URLRequest) async throws -> SpotifyHTTPResponse {
        SpotifyHTTPResponse(
            data: Data(body.utf8),
            statusCode: statusCode
        )
    }
}

private actor TestTokenStore: SpotifyTokenStoring {
    var token: SpotifyToken? = SpotifyToken(
        accessToken: "test-access",
        refreshToken: "test-refresh",
        tokenType: "Bearer",
        scopes: ["user-read-currently-playing"],
        expiresAt: Date.distantFuture
    )
    func load() -> SpotifyToken? { token }
    func save(_ token: SpotifyToken) { self.token = token }
    func delete() { token = nil }
}

private actor SuspendedAuthorization: SpotifyAuthorizing {
    var started = false
    var startedWaiter: CheckedContinuation<Void, Never>?
    var connectionWaiter: CheckedContinuation<Void, any Error>?

    func connect() async throws {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        try await withCheckedThrowingContinuation { continuation in
            connectionWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        if !started {
            await withCheckedContinuation { continuation in
                startedWaiter = continuation
            }
        }
    }

    func cancel() {
        connectionWaiter?.resume(throwing: CancellationError())
        connectionWaiter = nil
    }
}
