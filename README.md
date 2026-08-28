# SpotifyHelperApp

SpotifyHelperApp is a macOS SwiftUI app that connects to Spotify, reads the currently playing track, and provides the foundation for synchronized lyric display.

The first milestone implements browser sign-in with PKCE, Keychain session storage, automatic token refresh, current song details, manual playback refresh, and disconnect. Progress is a snapshot at the last refresh; lyrics lookup, automatic polling, and time-following highlights are not implemented yet.

Requires macOS 15.6 or later and Xcode with Swift 6 support.

## Sign in as a user

Open the configured app, click **Connect Spotify**, approve access in your browser, and return to the app. No developer account, API key, or Client Secret needs to be entered by the user. The application uses its own Client ID and stores each user's authorization locally in Keychain.

If the app reports that sign-in is unavailable because its Client ID is missing, the developer must configure the build first.

## Developer setup (once per application)

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Register this redirect URI exactly:

   ```text
   http://127.0.0.1/callback
   ```

   Spotify permits a dynamically selected port for an explicit loopback address. See the [redirect URI requirements](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).
3. Add testing accounts to the app's allowlist. Development Mode currently requires the app owner to have Premium and allows up to five authenticated users. Wider distribution requires Spotify approval; see [quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
4. Copy `Configuration/Spotify.local.xcconfig.example` to `Configuration/Spotify.local.xcconfig` and replace `your_spotify_client_id` with your app's Client ID. The local file is ignored by Git.
5. Open `SpotifyHelperApp.xcodeproj`, select the `SpotifyHelperApp` scheme and My Mac, then build and run. If needed, select your own signing team in Signing & Capabilities.
6. Click **Connect Spotify**, approve access in your browser, and return to the app. Start a song in Spotify and click **Refresh** to see updated metadata and position.

Do not add the Client Secret. Native authorization uses Authorization Code with PKCE and does not need it. Only `user-read-currently-playing` is requested. A process environment variable named `SPOTIFY_CLIENT_ID` may override the bundled value during development.

Disconnect cancels pending work and removes this app's saved tokens. It does not stop Spotify playback or revoke the app's grant in Spotify account settings.

## Reuse the sign-in flow

The browser sign-in process lives in `SpotifyKit`, including browser opening, PKCE, callback handling, token exchange, and cancellation cleanup. The app injects the package's public `SpotifyAuthorizationCoordinator` into its view model; there is no separate app-owned OAuth implementation.

See the [SpotifyKit integration guide](Packages/SpotifyKit/README.md) for setup, connect/restore/disconnect examples, and test injection.

## Verification

```sh
swift test --package-path Packages/SpotifyKit
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' test
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' build
```

Package tests use injected HTTP/token stores and a real local loopback listener. App view-model tests run without launching the app. Neither suite contacts Spotify, opens a browser, or touches your Keychain.

Live-account verification is still required: connect, play/pause and refresh, relaunch to restore the session, and disconnect. Automated tests do not verify Spotify dashboard configuration or access for a particular account.

See [docs/SpotifyLyricsAppPlan.md](docs/SpotifyLyricsAppPlan.md) for the implementation roadmap.
