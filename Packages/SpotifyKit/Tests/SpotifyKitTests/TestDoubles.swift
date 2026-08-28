import Foundation
@testable import SpotifyKit

actor MockSpotifyHTTPTransport: SpotifyHTTPTransport {
    private var responses: [SpotifyHTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [SpotifyHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> SpotifyHTTPResponse {
        recordedRequests.append(request)
        if responses.isEmpty {
            throw SpotifyError.network("No mock response was available.")
        }
        return responses.removeFirst()
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

actor MemorySpotifyTokenStore: SpotifyTokenStoring {
    private var token: SpotifyToken?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(token: SpotifyToken? = nil) {
        self.token = token
    }

    func load() -> SpotifyToken? {
        token
    }

    func save(_ token: SpotifyToken) {
        self.token = token
        saveCount += 1
    }

    func delete() {
        token = nil
        deleteCount += 1
    }

    func savedToken() -> SpotifyToken? {
        token
    }
}

func response(
    statusCode: Int,
    body: String = "",
    headers: [String: String] = [:]
) -> SpotifyHTTPResponse {
    SpotifyHTTPResponse(
        data: Data(body.utf8),
        statusCode: statusCode,
        headers: headers
    )
}

