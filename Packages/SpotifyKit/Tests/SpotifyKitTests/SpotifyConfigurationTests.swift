import Testing
@testable import SpotifyKit

@Test func defaultConfigurationUsesMinimumPlaybackScope() {
    let configuration = SpotifyConfiguration(clientID: "client-id")

    #expect(configuration.redirectPath == "/callback")
    #expect(configuration.redirectPort == 8888)
    #expect(configuration.scopes == ["user-read-currently-playing"])
}
