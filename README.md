# SpotifyHelperApp

SpotifyHelperApp is a macOS SwiftUI app that connects to Spotify, reads the currently playing track, and provides the foundation for synchronized lyric display.

The first milestone implements browser sign-in with PKCE, Keychain session storage, automatic token refresh, current song details, manual playback refresh, and disconnect. Progress is a snapshot at the last refresh; lyrics lookup, automatic polling, and time-following highlights are not implemented yet.

Requires macOS 15.6 or later and Xcode with Swift 6 support.

## Spotify setup

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Register this redirect URI exactly:

   ```text
   http://127.0.0.1/callback
   ```

   Spotify permits a dynamically selected port for an explicit loopback address. See the [redirect URI requirements](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).
3. Add the Spotify account used for testing to the app's allowlist when Development Mode requires it.
4. Copy `Configuration/Spotify.local.xcconfig.example` to `Configuration/Spotify.local.xcconfig` and replace `your_spotify_client_id` with your app's Client ID. The local file is ignored by Git.
5. Open `SpotifyHelperApp.xcodeproj`, select the `SpotifyHelperApp` scheme and My Mac, then build and run. If needed, select your own signing team in Signing & Capabilities.
6. Click **Connect Spotify**, approve access in your browser, and return to the app. Start a song in Spotify and click **Refresh** to see updated metadata and position.

Do not add the Client Secret. Native authorization uses Authorization Code with PKCE and does not need it. Only `user-read-currently-playing` is requested. A process environment variable named `SPOTIFY_CLIENT_ID` may override the bundled value during development.

Disconnect cancels pending work and removes this app's saved tokens. It does not stop Spotify playback or revoke the app's grant in Spotify account settings.

## Verification

```sh
swift test --package-path Packages/SpotifyKit
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' test
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' build
```

Package tests use injected HTTP/token stores and a real local loopback listener. App view-model tests run without launching the app. Neither suite contacts Spotify, opens a browser, or touches your Keychain.

Live-account verification is still required: connect, play/pause and refresh, relaunch to restore the session, and disconnect. Automated tests do not verify Spotify dashboard configuration or access for a particular account.

See [docs/SpotifyLyricsAppPlan.md](docs/SpotifyLyricsAppPlan.md) for the implementation roadmap.
