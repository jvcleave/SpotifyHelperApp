import Testing
@testable import SpotifyKit

@Test func defaultConfigurationUsesMinimumPlaybackScope() {
    let configuration = SpotifyConfiguration(clientID: "client-id")

    #expect(configuration.redirectPath == "/callback")
    #expect(configuration.scopes == ["user-read-currently-playing"])
}

