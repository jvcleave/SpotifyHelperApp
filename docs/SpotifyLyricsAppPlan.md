# Spotify Lyrics App Plan

## Purpose

Build a macOS SwiftUI app that connects to a user's Spotify account, identifies the currently playing song, retrieves lyrics, and presents those lyrics alongside the Spotify playback state.

This follows the same view/view-model/service separation used by LyricsApp. Spotify replaces imported audio files as the source of track metadata and playback position. Lyrics lookup and parsing remain reusable domain behavior rather than becoming part of the SwiftUI views.

## Intended user flow

1. The user launches the app.
2. The user connects their Spotify account.
3. The app securely restores the connection on later launches when possible.
4. The app reads the currently playing Spotify item.
5. If the item is a music track, the app uses its title, artists, album, and duration to find lyrics.
6. The app displays synchronized lyrics when a suitable timed result exists, or plain lyrics when it does not.
7. The app notices pause, resume, seek, and track-change events and updates its presentation.
8. The user can refresh, retry lyrics lookup, or disconnect Spotify.

## Product boundaries

The first version will read Spotify playback state. It will not start, pause, seek, skip, or otherwise control Spotify.

The app will not download, record, transform, or play Spotify audio. Spotify remains the playback application.

Episodes, advertisements, and unknown item types will be shown as unsupported for lyrics rather than treated as broken tracks.

Album artwork is optional for the first release. If it is added, the UI must follow Spotify's attribution, linking, and artwork rules.

## Synchronized lyrics policy decision

The project owner confirmed on August 28, 2026 that the policy checkpoint for time-following lyric highlighting is cleared. Synchronized presentation remains in scope.

Reference: <https://developer.spotify.com/documentation/web-api/reference/get-the-users-currently-playing-track>

## Project foundation

- [ ] Make the Xcode app target macOS-only.
- [ ] Align deployment with LyricsApp: macOS 15.6.
- [ ] Enable Swift 6 and complete strict concurrency.
- [ ] Keep observable UI models explicitly isolated to `@MainActor`.
- [ ] Enable outgoing network access for Spotify and lyrics requests.
- [ ] Enable incoming network access for the temporary loopback authorization callback.
- [ ] Add a local `Packages/SpotifyKit` Swift package.
- [ ] Add package and app tests to the Xcode project as needed.
- [ ] Add repository guidance based on the LyricsApp `AGENTS.md`, adjusted for SpotifyHelperApp's package names and responsibilities.

## Proposed architecture

```text
User action
  -> SpotifyLyricsView
  -> SpotifyLyricsViewModel action
  -> SpotifyKit authorization or playback service
  -> Sendable Spotify playback snapshot
  -> lyrics lookup through shared LyricsKit behavior
  -> Sendable lyrics result
  -> view-model display state
  -> SwiftUI presentation
```

### SwiftUI app

The app target owns presentation and macOS integration:

- `SpotifyLyricsView`
  - Renders connection state, currently playing track, lyrics, loading, empty, and error states.
  - Sends semantic actions to the view model.
  - Contains no HTTP, OAuth, Keychain, Spotify decoding, lyric lookup, matching, or time calculations.
- `SpotifyLyricsViewModel`
  - Is `@MainActor` and `@Observable`.
  - Owns the smallest useful presentation state.
  - Coordinates connect, disconnect, refresh, track change, and lyric lookup actions.
  - Owns and cancels UI-lifetime monitoring work.
  - Publishes typed display data and user-facing messages.
- Composition root
  - Constructs long-lived Spotify and lyrics services.
  - Injects services into the view model.
  - Supplies the Spotify Client ID and authorization configuration.

### SpotifyKit

`SpotifyKit` owns Spotify-specific domain and infrastructure behavior without importing SwiftUI:

- PKCE verifier and challenge generation
- OAuth authorization URL construction
- Callback state validation and authorization-code extraction
- Access-token exchange and refresh
- Keychain-backed token persistence through an injectable token-store boundary
- Authenticated Spotify Web API requests
- Currently-playing response decoding
- Playback snapshot and track metadata value types
- HTTP and Spotify error mapping
- `401`, `403`, `429`, cancellation, and retry behavior
- Short-lived loopback callback handling, unless a smaller app-owned browser adapter proves cleaner during implementation

Mutable services will own their isolation, normally through actors. Values crossing isolation boundaries will be small and `Sendable`.

### LyricsKit reuse

Do not duplicate LyricsApp's metadata matching, LRCLIB access, lyrics parsing, or content-resolution behavior.

- [ ] Decide how both applications will consume one shared LyricsKit implementation.
- [ ] Prefer a standalone/versioned LyricsKit package repository if both apps need portable builds.
- [ ] A local path dependency may be used during early development, but it must not become the permanent repository setup.
- [ ] Keep SpotifyKit independent of LyricsKit.
- [ ] Let the app translate a Spotify track snapshot into LyricsKit's lookup request.

This keeps Spotify access reusable and prevents either package from depending on SwiftUI or the other app.

## Spotify authorization design

Use Authorization Code with PKCE. A native app cannot safely protect a client secret, so no Client Secret will be placed in source code, build settings, resources, or Keychain.

1. Generate a cryptographically random PKCE verifier and OAuth state value.
2. Derive the SHA-256 PKCE challenge.
3. Start a temporary listener on an available `127.0.0.1` port.
4. Open Spotify's authorization page in the user's browser.
5. Receive the callback at `http://127.0.0.1:<port>/callback`.
6. Verify the callback state before accepting the code.
7. Exchange the code and verifier for access and refresh tokens.
8. Store token material in Keychain.
9. Stop the callback listener and clean up safely on success, failure, cancellation, or timeout.

Register the loopback URI in the Spotify Developer Dashboard using the explicit IP address. Do not use `localhost`. The authorization request and token exchange must use the same redirect URI, including the dynamically chosen port.

Request only this initial scope:

```text
user-read-currently-playing
```

References:

- <https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow>
- <https://developer.spotify.com/documentation/web-api/concepts/redirect_uri>
- <https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens>

## Configuration and credentials

- [ ] Create the app in the Spotify Developer Dashboard.
- [ ] Confirm the developer account meets Spotify's current Development Mode requirements.
- [ ] Add the Spotify account used for testing to the app allowlist if required.
- [ ] Register the loopback redirect URI.
- [ ] Add a local, ignored configuration file containing the Client ID.
- [ ] Add a checked-in example configuration with setup instructions.
- [ ] Fail at startup with a useful configuration message when the Client ID is absent.
- [ ] Never request, store, or embed the Client Secret.

The Client ID is public OAuth configuration, but keeping the developer-specific value outside the repository makes setup and ownership clearer.

## Domain values

The Spotify boundary should normalize the large API response into small values similar to these concepts:

```text
SpotifyPlaybackSnapshot
  track identity and Spotify URL
  title
  artist names
  album title
  artwork reference, if used
  duration
  sampled progress
  playing/paused state
  playback-state change timestamp
  local monotonic sample time
```

```text
SpotifyPlaybackContent
  track(snapshot)
  episode(summary)
  advertisement
  unknown
  nothingPlaying
```

Do not expose Spotify's full transport response to the view model.

## Playback monitoring and timing

The Web API provides `progress_ms`, `is_playing`, and a timestamp for the last playback-state change. It does not provide a continuous local clock.

The playback service will therefore create a snapshot when a response arrives. While that snapshot says playback is active, a local monotonic clock can estimate the current position:

```text
estimated position = sampled progress + monotonic elapsed time
```

Clamp the estimate to the track duration. A paused snapshot stays at its sampled progress.

Periodic API refreshes will re-anchor that estimate and detect:

- pause and resume
- seeks
- track changes
- playback ending
- playback moving to another device
- nothing playing

Implementation notes:

- [ ] Fetch once immediately after connection or session restoration.
- [ ] Begin with manual refresh while authorization and decoding are validated.
- [ ] Add cancellable monitoring at a conservative interval after the basic flow works.
- [ ] Stop monitoring when the view model no longer owns the session or the app is inactive.
- [ ] Reset lyrics state immediately when the Spotify track identity changes.
- [ ] Ignore stale asynchronous responses after cancellation or a newer track change.
- [ ] Respect `Retry-After` and apply backoff for `429` responses.
- [ ] Do not poll in a tight loop near lyric timestamps or track boundaries.

The UI may update its local highlighted-line presentation more frequently than Spotify is polled. Network polling and local visual updates are separate responsibilities.

## Lyrics lookup and presentation

When a new Spotify track appears:

1. Create a LyricsKit lookup request from track title, primary/all artists, album, and duration.
2. Resolve synchronized, plain, instrumental, or unavailable content through the shared resolver.
3. Cache the result by stable Spotify track ID during the app session.
4. Publish a typed display model for the view.
5. If synchronized lyrics are unavailable, show plain lyrics without attempting fake timing.
6. If the track is instrumental or lyrics are unavailable, show a clear empty state.

If synchronized presentation is approved, the active line is selected from parsed lyric timestamps and the estimated playback position. The view receives stable lyric-line IDs, display text, and active-state information; it does not search timestamps in `body`.

## Presentation states

The view model should distinguish these states rather than relying on loosely related booleans:

- Spotify is not configured
- Disconnected
- Connecting
- Connected, loading playback
- Nothing playing
- Unsupported Spotify content
- Loading lyrics for the current track
- Synchronized lyrics available
- Plain lyrics available
- Instrumental track
- Lyrics unavailable
- Recoverable failure with retry
- Authorization expired and reconnection required

Track identity, playback state, and lyrics state may change independently. The final state model should keep one writable owner for each fact without allowing an old lyric response to overwrite a newer track.

## Error and recovery behavior

- Authorization cancellation returns to the disconnected state without alarming error text.
- OAuth state mismatch fails securely and discards the authorization attempt.
- Invalid or expired refresh tokens are removed and require reconnection.
- A `401` may trigger one refresh-and-retry attempt.
- A `403` explains missing permission, account access, or Development Mode restrictions.
- A `429` respects Spotify's delay and does not retry immediately.
- A `204`/empty response becomes `nothingPlaying`, not an error.
- Network loss preserves the last clearly labeled snapshot when useful and offers retry.
- Lyrics lookup failure does not disconnect Spotify.
- Spotify failure does not corrupt a cached lyrics result.

## Milestones

### Milestone 1: Foundation

- [ ] Align project and concurrency settings.
- [ ] Add repository guidance.
- [ ] Add `SpotifyKit` and its test target.
- [ ] Add injectable HTTP and token-storage boundaries.
- [ ] Confirm clean package tests and macOS app build.

### Milestone 2: Spotify connection

- [ ] Implement and test PKCE primitives.
- [ ] Implement loopback authorization and callback cleanup.
- [ ] Implement token exchange, Keychain persistence, refresh, and disconnect.
- [ ] Build connected/disconnected UI states.
- [ ] Test authorization cancellation, denial, mismatch, timeout, and expired refresh token.

### Milestone 3: Currently playing

- [ ] Implement the currently-playing endpoint.
- [ ] Normalize track and non-track responses.
- [ ] Display song, artist, album, duration, progress, and playing state.
- [ ] Add manual refresh.
- [ ] Handle empty, unauthorized, forbidden, rate-limited, and offline responses.

### Milestone 4: Shared lyrics

- [ ] Establish the reusable LyricsKit dependency strategy.
- [ ] Translate Spotify metadata into a LyricsKit lookup request.
- [ ] Display synchronized, plain, instrumental, and unavailable results.
- [ ] Add stable track-based caching and stale-result protection.

### Milestone 5: Playback following

- [x] Complete the Spotify policy review for synchronized lyric highlighting.
- [ ] Add conservative, cancellable Spotify monitoring.
- [ ] Add monotonic local position estimation.
- [ ] Detect pause, resume, seek, and track changes.
- [ ] If permitted, highlight and scroll synchronized lyrics using view-model display data.
- [ ] Measure drift and tune the refresh/re-anchoring interval without aggressive polling.

### Milestone 6: Polish and release readiness

- [ ] Add accessible loading, error, connection, and lyric states.
- [ ] Add Spotify attribution and links where required.
- [ ] Review token and log privacy.
- [ ] Confirm no credentials or tokens are committed.
- [ ] Review Spotify Developer Terms and current API documentation again.
- [ ] Run all package tests and a clean macOS Xcode build.

## Test plan

### SpotifyKit tests

- [ ] PKCE verifier format and deterministic challenge fixture
- [ ] Authorization query, state, scope, and redirect URI
- [ ] Successful, denied, malformed, and mismatched callback parsing
- [ ] Token exchange and refresh response decoding
- [ ] Refresh responses that omit a replacement refresh token
- [ ] Secure removal on disconnect or invalid grant
- [ ] Currently-playing track decoding
- [ ] Episode, advertisement, unknown, null item, and empty-response behavior
- [ ] `401`, `403`, `429`, malformed data, and network failure
- [ ] Cancellation and single-retry limits
- [ ] Playback-position estimation for playing, paused, clamped, and re-anchored snapshots

### Lyrics integration tests

- [ ] Spotify metadata maps to the expected LyricsKit request
- [ ] A new track cancels or invalidates the old lookup
- [ ] Synchronized, plain, instrumental, and unavailable lyrics map to display state
- [ ] Cached lyrics are reused only for the matching track identity
- [ ] Lyrics errors remain independent of Spotify connection state

### App verification

- [ ] `swift test --package-path Packages/SpotifyKit`
- [ ] Run the shared LyricsKit package tests from its final location
- [ ] Build the SpotifyHelperApp macOS scheme with `xcodebuild`
- [ ] Test against a real Spotify account and active playback device
- [ ] Exercise play, pause, seek, skip, track end, device transfer, and no-active-playback cases
- [ ] Confirm relaunch restores authorization without exposing token values

## Decisions recorded

- macOS-only application for the first version
- Swift 6 with complete strict concurrency
- Authorization Code with PKCE; no embedded Client Secret
- Explicit `127.0.0.1` loopback callback
- Minimum initial scope: `user-read-currently-playing`
- Spotify read-only behavior; no playback controls in the first version
- SpotifyKit and LyricsKit remain independent reusable packages
- The app coordinates Spotify metadata and lyrics lookup
- Manual playback refresh before background monitoring
- Synchronized highlighting is approved for this project

## Open decisions

- [ ] Choose the permanent shared LyricsKit distribution method.
- [ ] Decide whether album artwork belongs in the first user-facing version.
- [ ] Choose the initial monitoring interval after measuring real API behavior.
- [x] Confirm whether synchronized lyric highlighting is permitted for this application.
- [ ] Decide whether a later release should include optional Spotify playback controls and the additional scopes they require.

## Completion definition

The core application is complete when a user can connect Spotify, relaunch without unnecessary reauthorization, see the current music track, retrieve the correct lyrics through shared LyricsKit behavior, and receive coherent updates when playback changes. Synchronized line following is part of completion.
