import Foundation

public struct SpotifyConfiguration: Equatable, Sendable {
    public let clientID: String
    public let redirectPath: String
    /// Match the registered dashboard port. Nil explicitly requests a dynamic port.
    public let redirectPort: UInt16?
    public let scopes: [String]

    public init(
        clientID: String,
        redirectPath: String = "/callback",
        redirectPort: UInt16? = 8888,
        scopes: [String] = ["user-read-currently-playing"]
    ) {
        self.clientID = clientID
        self.redirectPath = redirectPath
        self.redirectPort = redirectPort
        self.scopes = scopes
    }
}
