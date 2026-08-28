# SpotifyKit

A reusable macOS 15.6+ Swift 6 package for browser sign-in, read-only Spotify playback monitoring, and monotonic position estimation. It contains no SwiftUI views or lyrics dependency. Users approve access in Spotify's browser page; they do not create developer apps, copy keys, or enter a Client Secret.

## Configure the application once

The developer registers a Spotify app and supplies its public Client ID to `SpotifyConfiguration`. Bundle that ID in your application configuration; do not bundle a Client Secret. SpotifyKit uses [Authorization Code with PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow).

Register `http://127.0.0.1:8888/callback` in the Spotify Developer Dashboard. The coordinator binds that fixed loopback port and uses the same redirect URI for authorization and token exchange. If you customize `redirectPath` or `redirectPort`, register the corresponding URI instead. See Spotify's [redirect URI requirements](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).

If the configured port is occupied, sign-in fails before opening the browser with `SpotifyError.callbackPortUnavailable`. Close the other listener and retry; there is no automatic fallback to an unregistered port. The dashboard rejected a portless URI during this project's setup, so the default is explicitly `8888`. Setting `redirectPort: nil` opts into dynamic ports for tests or registrations known to accept them; it is not the normal app setup. Port `0` is rejected.

Sandboxed macOS apps need both outgoing network access and incoming network access for the temporary callback listener. No custom URL scheme or app delegate callback forwarding is required.

## Create the shared services

Construct and retain one session and one coordinator at the app or feature composition root, then inject them into your view model:

```swift
import SpotifyKit

let configuration = SpotifyConfiguration(clientID: "your-app-client-id")
let session = SpotifySession(configuration: configuration)
let signIn = SpotifyAuthorizationCoordinator(session: session)
```

Construction starts no network or browser work. The session defaults to Keychain storage keyed by the Client ID, so different Spotify applications do not reuse each other's tokens. Apps that need a separate storage namespace can inject `KeychainSpotifyTokenStore(service:account:)` or their own `SpotifyTokenStoring` implementation.

## Connect and read playback

From a view-model action triggered by the user:

```swift
try await signIn.connect()
let playback = try await session.currentlyPlaying()
```

The coordinator creates fresh PKCE/state values, opens the default browser, receives and validates the callback, exchanges the code, and saves tokens through the session. It closes the listener on success, denial, error, cancellation, or timeout. The default callback deadline is 120 seconds. A second simultaneous connection attempt throws `SpotifyError.authorizationInProgress`.

Call `restoreConnection()` on a later launch to check for saved authorization without opening the browser:

```swift
if try await session.restoreConnection() {
    let playback = try await session.currentlyPlaying()
    // Publish a display model after checking cancellation.
}
```

Restoration checks storage; the playback request validates/refreshes the saved token as needed. Handle `SpotifyError.notConnected` by offering sign-in again. Present authorization denial and cancellation without treating them as unexpected failures.

## Cancel and disconnect

Canceling the task awaiting `connect()` also cancels its owned sign-in work. For an explicit Cancel action:

```swift
await signIn.cancel()
```

This waits for owned work to finish and is safe to repeat. It does not erase an existing session or close the user's browser tab. For Disconnect, cancel app-owned playback work and then:

```swift
await signIn.cancel()
try await session.disconnect()
```

Keep reconnect disabled until cleanup finishes. Disconnect removes local tokens, not Spotify's account-level authorization grant, and does not control playback.

## Monitor playback and estimate position

Create one monitor per session at the composition root and retain it for the feature's lifetime:

```swift
let monitor = SpotifyPlaybackMonitor(
    source: session,
    pollInterval: .seconds(10)
)
```

Subscribe from a view model, then start after authorization or successful restoration:

```swift
let updates = await monitor.updates()
let observation = Task {
    for await state in updates {
        if Task.isCancelled { return }
        // Project state.reading, isMonitoring, isRefreshing, error, and retryAt
        // into main-actor presentation values. Preserve the reading on errors.
    }
}
await monitor.start()
```

`start()` performs an initial refresh and starts one polling loop. Repeated starts do not duplicate work. `refresh()` coalesces concurrent requests and respects cooldowns even when automatic monitoring is stopped. Route manual refreshes through this monitor, not directly through the session.

`SpotifyPlaybackMonitorState.reading` contains the normalized content, local receipt date, and an optional `SpotifyPlaybackTimeline` for track content. Each successful response replaces the reading, including empty or unsupported content. `revision` increases within a monitor so consumers combining explicit state reads and stream updates can reject older presentations. Streams buffer only the latest state.

For smooth display, retain the latest reading and sample its timeline with a local display timer:

```swift
if let reading = await monitor.state.reading {
    let estimate = reading.timeline?.estimate()
    // estimate?.seconds is nil when Spotify did not report progress.
    // estimate?.isStale indicates the sample is too old for further estimation.
}
```

The timeline anchors progress to `ContinuousClock` at receipt, not Spotify's playback-state-change timestamp. It advances only a playing snapshot, clamps to track duration, and stops extrapolating after the greater of 30 seconds or twice the configured poll interval. A paused snapshot stays fixed. A new response re-anchors after seeks, pauses, and track changes. A standalone `SpotifyPlaybackTimeline(track:)` is also available for clients managing their own snapshots.

This is an **estimate**, not continuous or sample-accurate playback telemetry. Pause/seek changes are detected at the next API response. Local drawing frequency must not determine network frequency. The default is 10 seconds; the package clamps custom intervals below one second. Tune conservatively for your quota, not for animation smoothness.

Transient network/server failures freeze the timeline and back off. `429` respects `Retry-After` (or a default delay when missing), including manual refresh and stop/start. Permission or authorization failures stop automatic monitoring; `notConnected` also clears the previous reading. Surface errors rather than silently treating old metadata as current. See Spotify's [rate-limit guidance](https://developer.spotify.com/documentation/web-api/concepts/rate-limits).

The feature owner controls lifecycle:

```swift
await monitor.stop() // Freeze, cancel request/poll, and await cleanup.
await monitor.start() // Fresh request on resume, unless a cooldown applies.

// On disconnect, before erasing session credentials:
observation.cancel()
await monitor.stop(clearPlayback: true)
await signIn.cancel()
try await session.disconnect()
```

Stopping is safe to repeat. Cancellation of the final stream subscription also stops owned work, but explicit cleanup is recommended. Canceling only a task awaiting `start()` or `refresh()` does not cancel a shared request; use `stop()`. Keep reconnect disabled until cleanup finishes. `stop()` does not send any Spotify playback command.

The demo suspends monitoring on inactivity/sleep and keeps an explicit manual stop across reactivation. Other clients can choose their own feature lifecycle without importing the demo or LyricsKit.

## Injection and tests

`SpotifyBrowserOpening` supplies an injectable browser opener, with `SystemSpotifyBrowser` as the macOS default. `SpotifyAuthorizing` allows view models to use test doubles. HTTP and token storage are independently injectable into `SpotifySession`. `SpotifyPlaybackProviding` lets a monitor consume fake playback snapshots; package tests additionally inject clocks and sleep behavior for deterministic timing and retry checks.

Package tests simulate browser redirects against a real local loopback listener, with fake Spotify HTTP responses and in-memory token storage. They never launch a browser, contact Spotify, or access the real Keychain.

```sh
swift test --package-path Packages/SpotifyKit
```

## Spotify account access

Browser authorization does not bypass Spotify's access restrictions. Development Mode currently requires a Premium app owner and supports up to five allowlisted users; wider access requires Spotify approval. See the current [quota-mode documentation](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) before distributing a build.
