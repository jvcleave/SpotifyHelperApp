# SpotifyKit

A reusable macOS 15.6+ Swift 6 package for browser sign-in and read-only Spotify playback information. It contains no SwiftUI views. Users approve access in Spotify's browser page; they do not create developer apps, copy keys, or enter a Client Secret.

## Configure the application once

The developer registers a Spotify app and supplies its public Client ID to `SpotifyConfiguration`. Bundle that ID in your application configuration; do not bundle a Client Secret. SpotifyKit uses [Authorization Code with PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow).

Register `http://127.0.0.1/callback` in the Spotify Developer Dashboard. The package binds an available loopback port and uses the same redirect URI for authorization and token exchange. If you customize `redirectPath`, register the corresponding path instead. See Spotify's [redirect URI requirements](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).

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

## Injection and tests

`SpotifyBrowserOpening` supplies an injectable browser opener, with `SystemSpotifyBrowser` as the macOS default. `SpotifyAuthorizing` allows view models to use test doubles. HTTP and token storage are independently injectable into `SpotifySession`.

Package tests simulate browser redirects against a real local loopback listener, with fake Spotify HTTP responses and in-memory token storage. They never launch a browser, contact Spotify, or access the real Keychain.

```sh
swift test --package-path Packages/SpotifyKit
```

## Spotify account access

Browser authorization does not bypass Spotify's access restrictions. Development Mode currently requires a Premium app owner and supports up to five allowlisted users; wider access requires Spotify approval. See the current [quota-mode documentation](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) before distributing a build.
