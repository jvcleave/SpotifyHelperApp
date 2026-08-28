# Spotify Helper and Future Lyrics App Plan

## Product decision

Keep the Spotify integration useful without lyrics:

- **SpotifyKit** is the reusable package for browser authorization, token storage, Web API access, playback monitoring, and position estimation.
- **SpotifyHelperApp** is the standalone SpotifyKit reference app. It does not import LyricsKit or look up lyrics.
- **LyricsKit** remains the reusable lyrics implementation used by LyricsApp.
- A future, separate **SpotifyLyricsApp** will compose SpotifyKit and LyricsKit. Neither package will depend on the other.

The original use case is preserved: a user connects Spotify instead of importing an audio file, retrieves lyrics for the current song, and follows timed lyrics using estimated playback position. That combined experience belongs in the future app, not the Spotify helper demo.

## Progress — August 28, 2026

Browser sign-in and current-track retrieval are working against the owner's real Spotify account, as confirmed by the owner. The registered redirect is `http://127.0.0.1:8888/callback`; the developer-specific Client ID remains in a Git-ignored xcconfig file.

The helper now implements automatic playback monitoring, estimated live position, Start/Stop Monitoring, Refresh Now, last-update information, stale/error presentation, and inactive/sleep cleanup. Its window and header are named **Spotify Helper**.

Automated checks cover 58 SpotifyKit tests and 11 hostless app tests. These use fake Spotify responses and in-memory credentials; they do not launch the app, contact Spotify, open a browser, or touch the real Keychain. Live monitoring, relaunch persistence, and real-device drift still need the smoke tests below.

No lyrics integration, playback controls, album artwork, or additional scopes are included in this milestone.

## Architecture

Feature flow stays consistent with LyricsApp's guidance:

```text
View action or app lifecycle event
  -> SpotifyHelperViewModel (@MainActor, @Observable)
  -> SpotifyKit service
  -> Sendable playback state / timeline
  -> typed view-model display values
  -> SwiftUI views
```

- The composition root creates the session, authorization coordinator, and playback monitor.
- SpotifyKit owns OAuth, callback resources, token refresh, HTTP, decoding, polling, retry pacing, cancellation, and monotonic position estimates.
- The view model projects package state, formats strings, and runs a local display timer. It sends no network requests on display ticks.
- Views render display values and send semantic actions. Child views receive plain values and closures.
- The future combined app will translate Spotify metadata into LyricsKit requests and coordinate lyrics state independently of connection state.

## Milestone 1: Foundation and authorization

- [x] macOS 15.6, Swift 6, complete strict concurrency.
- [x] SpotifyKit package and injectable HTTP/token-store boundaries.
- [x] Guidance based on LyricsApp's AGENTS.md.
- [x] PKCE, cryptographic state, callback origin/state validation.
- [x] Reusable browser sign-in through SpotifyAuthorizationCoordinator.
- [x] Injectable browser opener; no end-user developer credentials.
- [x] Fixed loopback port 8888 with recoverable port-conflict errors.
- [x] Listener cleanup on success, denial, error, timeout, and cancellation.
- [x] Keychain session storage, token refresh, and local disconnect.
- [x] Developer Client ID setup without a Client Secret.
- [x] Minimum scope: user-read-currently-playing.
- [x] Owner-confirmed live authorization and current-track retrieval.
- [ ] Owner-confirmed restoration after quitting and relaunching.
- [ ] Confirm account allowlisting and quota requirements for any additional testers.

## Milestone 2: Standalone Spotify helper demo

- [x] Normalize track, unsupported content, and nothing-playing responses.
- [x] Display song, artists, album, duration, and last reported playing/paused state.
- [x] Rename the UI and view model to Spotify Helper.
- [x] Keep SpotifyHelperApp free of LyricsKit dependencies.
- [x] Reusable SpotifyPlaybackMonitor actor with a configurable 10-second default.
- [x] One owned polling loop; coalesced manual/automatic requests.
- [x] AsyncStream state updates and explicit cleanup.
- [x] Monotonic SpotifyPlaybackTimeline with unavailable, paused, clamped, frozen, and stale estimates.
- [x] Local display refresh every 250 ms without additional Spotify requests.
- [x] Re-anchor on fresh samples after pause/resume, seeks, and track changes.
- [x] Start/Stop Monitoring, Refresh Now, last-update information, and error messages.
- [x] Suspend on inactivity/sleep; refresh on active wake/resume.
- [x] Preserve an explicit manual stop across lifecycle changes.
- [x] Cancel requests and clear playback on disconnect.
- [x] Respect Retry-After across automatic/manual refresh and stop/start.
- [x] Back off transient failures, retain and freeze useful previous data.
- [x] Stop automatic requests on permission/authentication failures.
- [x] Reject late canceled responses and older presentation updates.
- [x] Update package integration examples and regression tests.
- [ ] Run the live monitoring smoke test below.

### Timing contract

The Web API reports sampled progress and playing state, not a continuous clock. While a fresh snapshot says playback is active:

```text
estimated position = sampled progress + monotonic elapsed time
```

Clamp to track duration. Paused or missing progress never advances. At the default interval, extrapolation stops after 30 seconds without a fresh sample. Stopping or encountering a request error freezes the position immediately.

Polls detect changes at the next response, so seek/pause/track-change detection can lag. This is not sample-accurate synchronization. Do not increase network frequency to match animation or lyric timestamps.

## Milestone 3: Future separate SpotifyLyricsApp

No new app or package dependency is created as part of the helper milestone.

- [ ] Choose the portable distribution/versioning strategy for LyricsKit and SpotifyKit.
- [ ] Create the separate macOS composition app when requested.
- [ ] Convert track title, artists, album, and duration into a LyricsKit lookup request.
- [ ] Reuse existing LRCLIB, ranking, parsing, and LyricsContentResolver behavior.
- [ ] Display synchronized, plain, instrumental, and unavailable results.
- [ ] Cancel or invalidate lookup results when track identity changes.
- [ ] Cache results by stable track identity.
- [ ] Keep lyrics errors independent of Spotify connection state.
- [ ] Use the package timeline to select and scroll timed lines via view-model display values.
- [ ] Measure drift with real playback before claiming reliable synchronized following.

The owner confirmed on August 28, 2026 that the project's synchronized-lyrics policy checkpoint is cleared. That recorded project decision remains in place; it is not a claim of broader Spotify approval or a substitute for distribution requirements.

## Verification

- [x] Package tests: authorization, callback cleanup, tokens, decoding, and recovery.
- [x] Timeline tests: monotonic elapsed time, pause, unknown progress, bounds, stale cutoff, freeze, and new-snapshot re-anchoring.
- [x] Monitor tests: periodic polling, repeated start, concurrent refresh, cancellation, final-subscriber cleanup, retry cooldown, offline recovery, revoked authorization, and ignored late responses.
- [x] App tests: formatted display, denial, failures, disconnect, lifecycle suspension, manual stop persistence, rapid lifecycle changes, and retained track on error.
- [x] Build and test the macOS app without launching the production composition root.
- [x] Preserve ignored local configuration; never commit client secrets or tokens.

Commands:

```sh
swift test --package-path Packages/SpotifyKit
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' test
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' build
```

### Live smoke test — still to do

- [ ] Play a song: position advances smoothly while the helper is active.
- [ ] Pause/resume in Spotify: the next update corrects the estimate.
- [ ] Seek forward/backward: the next update re-anchors position.
- [ ] Skip/change tracks: no previous track data remains after the next response.
- [ ] Stop Monitoring: position freezes; Refresh Now still updates once.
- [ ] Restart monitoring: a fresh response resumes estimation.
- [ ] Switch away/back and sleep/wake: polling suspends and resumes cleanly.
- [ ] Stop manually, switch away/back: monitoring remains stopped.
- [ ] Test no playback, track end, and playback on another Spotify device.
- [ ] Disconnect and reconnect: old track data never reappears.
- [ ] Quit/relaunch: saved authorization restores without another browser sign-in.
- [ ] Observe real network loss and recovery; confirm stale position is labeled.

## Later decisions

Artwork, playback controls, extra scopes, background monitoring preferences, package distribution, and release readiness are separate follow-up decisions. Review Spotify's current requirements before distribution.

References: [currently playing](https://developer.spotify.com/documentation/web-api/reference/get-the-users-currently-playing-track), [PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow), [redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri), [rate limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits), and [quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
