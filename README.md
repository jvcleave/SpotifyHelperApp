# SpotifyHelperApp

SpotifyHelperApp is a macOS SwiftUI app that connects to Spotify, reads the currently playing track, and provides the foundation for synchronized lyric display.

## Spotify setup

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Register this redirect URI exactly:

   ```text
   http://127.0.0.1/callback
   ```

   Spotify permits a dynamically selected port for an explicit loopback address.
3. Add the Spotify account used for testing to the app's allowlist when Development Mode requires it.
4. In the SpotifyHelperApp target's build settings, set the user-defined `SPOTIFY_CLIENT_ID` value to the app's Client ID.

Do not add the Client Secret. Native authorization uses Authorization Code with PKCE and does not need it.

## Verification

```sh
swift test --package-path Packages/SpotifyKit
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' build
```

See [docs/SpotifyLyricsAppPlan.md](docs/SpotifyLyricsAppPlan.md) for the implementation roadmap.

