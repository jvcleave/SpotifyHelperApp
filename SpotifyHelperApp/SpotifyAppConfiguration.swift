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
                "Create Configuration/Spotify.local.xcconfig with SPOTIFY_CLIENT_ID set to your Client ID, then rebuild. See README for Spotify dashboard setup."
            )
        }

        return SpotifyConfiguration(clientID: clientID)
    }
}
