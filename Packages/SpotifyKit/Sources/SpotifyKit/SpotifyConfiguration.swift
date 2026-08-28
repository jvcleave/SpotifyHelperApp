import Foundation

public struct SpotifyConfiguration: Equatable, Sendable {
    public let clientID: String
    public let redirectPath: String
    public let scopes: [String]

    public init(
        clientID: String,
        redirectPath: String = "/callback",
        scopes: [String] = ["user-read-currently-playing"]
    ) {
        self.clientID = clientID
        self.redirectPath = redirectPath
        self.scopes = scopes
    }
}

