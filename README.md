# SpotifyHelperApp

<img width="942" height="812" alt="image" src="https://github.com/user-attachments/assets/3e8ad0ee-b845-4948-8eec-71f1579747b1" />

SpotifyHelperApp is a standalone macOS SwiftUI reference app for **SpotifyKit**. It connects to Spotify and demonstrates current-track metadata, playback monitoring, and estimated live position. It has no lyrics dependency.

The app includes browser sign-in with PKCE, Keychain session storage, automatic token refresh, current song details, Start/Stop Monitoring, Refresh Now, and disconnect. A future separate SpotifyLyricsApp can combine SpotifyKit with LyricsKit; neither package needs to depend on the other.

Requires macOS 15.6 or later and Xcode with Swift 6 support.

## Sign in as a user

Open the configured app, click **Connect Spotify**, approve access in your browser, and return to the app. No developer account, API key, or Client Secret needs to be entered by the user. The application uses its own Client ID and stores each user's authorization locally in Keychain.

If the app reports that sign-in is unavailable because its Client ID is missing, the developer must configure the build first.

## Developer setup (once per application)

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Register this redirect URI exactly:

   ```text
   http://127.0.0.1:8888/callback
   ```

   This matches the package's default fixed port. Although Spotify documents dynamic loopback ports, its dashboard rejected the portless URI during setup. See the [redirect URI requirements](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).
3. Add testing accounts to the app's allowlist. Development Mode currently requires the app owner to have Premium and allows up to five authenticated users. Wider distribution requires Spotify approval; see [quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
4. Copy `Configuration/Spotify.local.xcconfig.example` to `Configuration/Spotify.local.xcconfig` and replace `your_spotify_client_id` with your app's Client ID. The local file is ignored by Git.
5. Open `SpotifyHelperApp.xcodeproj`, select the `SpotifyHelperApp` scheme and My Mac, then build and run. If needed, select your own signing team in Signing & Capabilities.
6. Click **Connect Spotify**, approve access in your browser, and return to the app. Start a song in Spotify; the app refreshes playback automatically while active. **Refresh Now** requests an immediate update when no retry cooldown is in effect.

Do not add the Client Secret. Native authorization uses Authorization Code with PKCE and does not need it. Only `user-read-currently-playing` is requested. A process environment variable named `SPOTIFY_CLIENT_ID` may override the bundled value during development.

If port `8888` is already in use, close the other sign-in attempt or application and retry. The package does not silently switch ports: the listener, authorization request, and token exchange must match the registered redirect. To use another fixed port, change `SpotifyConfiguration.redirectPort` and the dashboard registration together.

Disconnect cancels pending work and removes this app's saved tokens. It does not stop Spotify playback or revoke the app's grant in Spotify account settings.

## Reuse the sign-in flow

The browser sign-in process lives in `SpotifyKit`, including browser opening, PKCE, callback handling, token exchange, and cancellation cleanup. The app injects the package's public `SpotifyAuthorizationCoordinator` into its view model; there is no separate app-owned OAuth implementation.

See the [SpotifyKit integration guide](Packages/SpotifyKit/README.md) for setup, connect/restore/disconnect examples, and test injection.

## Playback monitoring demo

- SpotifyKit polls every 10 seconds by default. The UI updates its local estimate every 250 ms without extra API calls.
- Fresh samples correct position after pause, resume, seeks, and track changes. Detection can lag until the next poll; this is not sample-accurate synchronization or a Spotify push stream.
- Paused tracks do not advance, missing position stays unavailable, and estimates never exceed track duration. Without a fresh response, extrapolation stops after 30 seconds at the default interval.
- Network failures freeze the last known position and show a warning. `Retry-After` and backoff apply to automatic and manual refreshes; revoked authorization requires reconnecting.
- **Stop Monitoring** freezes the display without stopping Spotify. **Refresh Now** still works while monitoring is stopped.
- Monitoring suspends while the app is inactive or the Mac sleeps, resumes with a fresh request when active again, and stops when the window closes. An explicit manual stop stays stopped across those lifecycle changes.

Only read-only currently-playing access is used. This milestone adds no playback controls, lyrics lookup, artwork, or additional scopes. Poll intervals are configurable in the package; choose them conservatively for your application's quota and follow Spotify's [rate-limit guidance](https://developer.spotify.com/documentation/web-api/concepts/rate-limits).

## Verification

```sh
swift test --package-path Packages/SpotifyKit
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' test
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' build
```

Package tests use injected HTTP/token stores and a real local loopback listener. App view-model tests run without launching the app. Neither suite contacts Spotify, opens a browser, or touches your Keychain.

The owner has confirmed live browser sign-in and current-track retrieval. The new monitoring behavior still needs a live smoke test: play/pause, seek, skip, stop/start monitoring, switch away/back, sleep/wake, relaunch to restore the session, and disconnect. Automated tests do not verify Spotify dashboard configuration or access for a particular account.

See [docs/SpotifyLyricsAppPlan.md](docs/SpotifyLyricsAppPlan.md) for the implementation roadmap.
