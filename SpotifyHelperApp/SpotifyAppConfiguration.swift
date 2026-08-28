import Foundation
import SpotifyKit

struct SpotifyAppConfiguration {
    static func load() throws -> SpotifyConfiguration {
        let environmentClientID = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"]
        let bundledClientID = Bundle.main.object(forInfoDictionaryKey: "SPOTIFY_CLIENT_ID") as? String
        let candidateClientID = environmentClientID ?? bundledClientID ?? ""
        let clientID = candidateClientID.trimmingCharacters(in: .whitespacesAndNewlines)

        if clientID.isEmpty || clientID == "$(SPOTIFY_CLIENT_ID)" {
            throw SpotifyError.invalidConfiguration(
                "This build is missing its Spotify Client ID. The app developer needs to configure Spotify before sign-in is available."
            )
        }

        return SpotifyConfiguration(clientID: clientID)
    }
}
