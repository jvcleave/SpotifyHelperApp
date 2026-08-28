import Foundation
import Security

public struct SpotifyToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let scopes: [String]
    public let expiresAt: Date

    public init(
        accessToken: String,
        refreshToken: String,
        tokenType: String,
        scopes: [String],
        expiresAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scopes = scopes
        self.expiresAt = expiresAt
    }
}

public protocol SpotifyTokenStoring: Sendable {
    func load() async throws -> SpotifyToken?
    func save(_ token: SpotifyToken) async throws
    func delete() async throws
}

public actor KeychainSpotifyTokenStore: SpotifyTokenStoring {
    private let service: String
    private let account: String

    public init(
        service: String = "com.jvclabs.SpotifyHelperApp.spotify",
        account: String = "authorization-token"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> SpotifyToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw SpotifyError.tokenStorage("The saved Spotify connection could not be read.")
        }
        if let data = result as? Data {
            do {
                return try JSONDecoder().decode(SpotifyToken.self, from: data)
            } catch {
                throw SpotifyError.tokenStorage("The saved Spotify connection is invalid. Disconnect and connect again.")
            }
        }
        throw SpotifyError.tokenStorage("The saved Spotify connection is invalid. Disconnect and connect again.")
    }

    public func save(_ token: SpotifyToken) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            throw SpotifyError.tokenStorage("The Spotify connection could not be saved.")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw SpotifyError.tokenStorage("The Spotify connection could not be saved.")
        }

        var addQuery = query
        for (attributeName, attributeValue) in attributes {
            addQuery[attributeName] = attributeValue
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw SpotifyError.tokenStorage("The Spotify connection could not be saved.")
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SpotifyError.tokenStorage("The saved Spotify connection could not be removed.")
        }
    }
}

