# SpotifyHelperApp Agent Guidance

## Scope and project shape

This repository contains two layers:

- `SpotifyHelperApp/` is the macOS SwiftUI reference app.
- `Packages/SpotifyKit/` is the reusable Swift package and the home of Spotify authorization, token persistence, Web API access, playback decoding, and playback models.

Keep the dependency direction one-way: `SpotifyHelperApp` may import `SpotifyKit`; `SpotifyKit` must not depend on the app or SwiftUI.

The deployment and language baseline is Swift 6 with complete strict concurrency. The app and package target macOS 15.6.

## Architecture

Use this flow for feature work:

```text
User action
  -> SwiftUI view
  -> SpotifyLyricsViewModel action
  -> SpotifyKit service or value-type helper
  -> Sendable result
  -> view-model presentation state
  -> SwiftUI view
```

### SwiftUI views

- Keep views focused on layout, styling, bindings, navigation/presentation, and short-lived interaction state.
- Views must not call networking, authorization, token stores, response decoders, or other domain services directly.
- Send semantic actions to the view model rather than using `.onChange` to synchronize owners.
- Render typed display data prepared by the view model. Do not sort, filter, group, or format domain collections in `body`.
- Presentation strings derived from domain values belong in display models or the view model.
- Child views receive the smallest practical set of plain display values and action closures. Do not give a child access to a service.
- A view that creates an `@Observable` view model stores it with `@State`; a view that receives one uses a plain stored property.

### View models

- SwiftUI-observed view models are `@MainActor` and use the Observation framework (`@Observable`).
- View models own loading/content/empty/error state, display models, validation messages, and user-facing actions.
- Mark injected dependencies, task handles, caches, and other non-presentation bookkeeping with `@ObservationIgnored`.
- Keep one writable source of truth for each fact.
- A view model may cancel UI-owned work, but a service owns cleanup for work and resources it starts.
- Check cancellation before publishing asynchronous results that may be stale.

### SpotifyKit services and models

- Keep OAuth construction, PKCE, token exchange/refresh, Keychain access, networking, decoding, pacing, and service errors in `SpotifyKit`.
- Do not import SwiftUI or retain app view models in `SpotifyKit`.
- Cross concurrency boundaries with small `Sendable` requests, results, snapshots, events, and IDs.
- Every mutable service owns its isolation. Prefer an actor for naturally serialized asynchronous state.
- Do not use `@MainActor` merely to silence concurrency errors.
- Keep recoverable API, token, callback, and user-data failures meaningful. Do not crash.
- Public `SpotifyKit` API changes must update package tests and app callers together.

### Dependencies and ownership

- Construct long-lived services at the app composition root and inject them into the view model.
- Keep default dependencies convenient for the app while preserving injectable boundaries for tests and previews.
- The code that creates a listener, connection, task, or token owns its cleanup. Cleanup must be explicit and safe to repeat.
- `SpotifyKit` and the future shared `LyricsKit` dependency remain independent; the app composes them.

## Swift style

Apply these rules to newly written or materially edited Swift:

- Prefer explicit, imperative control flow and obvious, local mutation.
- Use `switch` when branching on one value. Use `if`/`else` for general branching; do not introduce `guard` merely for compactness.
- Avoid fluent chains when they hide mutation or side effects.
- Do not create a one-use helper merely to shorten its caller.
- Do not add extensions to types owned by this repository.
- Use descriptive loop and value names.
- Avoid semantic prepositions such as `from`, `with`, `using`, and `for` in external parameter labels.
- Keep a one-parameter declaration or call on one line when it fits. Format declarations and calls with two or more parameters across multiple lines.
- Preserve surrounding style and avoid unrelated formatting churn.

## Testing and verification

Add focused tests beside the package behavior they protect. From the repository root, run:

```sh
swift test --package-path Packages/SpotifyKit
```

For app or integration changes, also run the app view-model tests and build the macOS scheme:

```sh
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' test
xcodebuild -project SpotifyHelperApp.xcodeproj -scheme SpotifyHelperApp -destination 'platform=macOS' build
```

Use injected HTTP and token-store boundaries. Tests must not contact Spotify, open a browser, or mutate the user's real Keychain. The hostless app test target compiles the view model and its dependencies directly so testing never launches the production composition root.

## Before handing off Swift changes

- Confirm views contain presentation and local interaction only.
- Confirm reusable Spotify behavior lives in `SpotifyKit`.
- Confirm observable state is the smallest useful UI projection and bookkeeping is ignored by Observation.
- Confirm mutable services have explicit isolation and crossing values are `Sendable`.
- Confirm callback listeners and tasks clean up on success, failure, timeout, and cancellation.
- Confirm token, empty-playback, cancellation, remote-error, and retry paths remain coherent.
- Run the package tests and macOS app build, and report anything that could not be verified.
