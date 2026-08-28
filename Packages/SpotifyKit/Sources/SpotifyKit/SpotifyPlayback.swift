import Foundation

public struct SpotifyTrackPlayback: Equatable, Sendable {
    public let id: String
    public let title: String
    public let artists: [String]
    public let albumTitle: String
    public let durationMilliseconds: Int
    public let progressMilliseconds: Int
    public let isPlaying: Bool
    public let playbackStateChangedAt: Date?
    public let sampledAt: Date
    public let spotifyURL: URL?

    public init(
        id: String,
        title: String,
        artists: [String],
        albumTitle: String,
        durationMilliseconds: Int,
        progressMilliseconds: Int,
        isPlaying: Bool,
        playbackStateChangedAt: Date?,
        sampledAt: Date,
        spotifyURL: URL?
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.albumTitle = albumTitle
        self.durationMilliseconds = durationMilliseconds
        self.progressMilliseconds = progressMilliseconds
        self.isPlaying = isPlaying
        self.playbackStateChangedAt = playbackStateChangedAt
        self.sampledAt = sampledAt
        self.spotifyURL = spotifyURL
    }
}

public struct SpotifyUnsupportedPlayback: Equatable, Sendable {
    public let type: String
    public let title: String?

    public init(
        type: String,
        title: String?
    ) {
        self.type = type
        self.title = title
    }
}

public enum SpotifyPlaybackContent: Equatable, Sendable {
    case track(SpotifyTrackPlayback)
    case unsupported(SpotifyUnsupportedPlayback)
    case nothingPlaying
}

struct SpotifyCurrentlyPlayingResponse: Decodable {
    struct PlaybackItem: Decodable {
        struct Artist: Decodable {
            let name: String
        }

        struct Album: Decodable {
            let name: String
        }

        struct ExternalURLs: Decodable {
            let spotify: URL?
        }

        let id: String?
        let uri: String?
        let name: String
        let type: String?
        let artists: [Artist]?
        let album: Album?
        let durationMilliseconds: Int?
        let externalURLs: ExternalURLs?

        enum CodingKeys: String, CodingKey {
            case id
            case uri
            case name
            case type
            case artists
            case album
            case durationMilliseconds = "duration_ms"
            case externalURLs = "external_urls"
        }
    }

    let timestamp: Int64?
    let progressMilliseconds: Int?
    let isPlaying: Bool
    let currentlyPlayingType: String?
    let item: PlaybackItem?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case progressMilliseconds = "progress_ms"
        case isPlaying = "is_playing"
        case currentlyPlayingType = "currently_playing_type"
        case item
    }
}

