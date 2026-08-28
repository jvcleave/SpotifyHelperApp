// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpotifyKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SpotifyKit",
            targets: ["SpotifyKit"]
        )
    ],
    targets: [
        .target(name: "SpotifyKit"),
        .testTarget(
            name: "SpotifyKitTests",
            dependencies: ["SpotifyKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)

