import Foundation

public struct SpotifyHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(
        data: Data,
        statusCode: Int,
        headers: [String: String] = [:]
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    public func header(name: String) -> String? {
        let normalizedName = name.lowercased()
        return headers.first { header in
            header.key.lowercased() == normalizedName
        }?.value
    }
}

public protocol SpotifyHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SpotifyHTTPResponse
}

public struct URLSessionSpotifyHTTPTransport: SpotifyHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> SpotifyHTTPResponse {
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse {
            var headers: [String: String] = [:]
            for (headerName, headerValue) in httpResponse.allHeaderFields {
                headers[String(describing: headerName)] = String(describing: headerValue)
            }
            return SpotifyHTTPResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                headers: headers
            )
        }
        throw SpotifyError.invalidResponse
    }
}

