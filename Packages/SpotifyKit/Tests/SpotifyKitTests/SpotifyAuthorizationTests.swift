import Foundation
import Testing
@testable import SpotifyKit

@Test func pkceChallengeMatchesRFC7636Fixture() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    let challenge = SpotifyAuthorization.codeChallenge(codeVerifier: verifier)

    #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func authorizationRequestContainsMinimumScopeAndPKCEValues() throws {
    let configuration = SpotifyConfiguration(clientID: "client-id")
    let authorization = SpotifyAuthorization(configuration: configuration)
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let verifier = String(repeating: "a", count: 43)

    let request = try authorization.makeRequest(
        redirectURI: redirectURI,
        codeVerifier: verifier,
        state: "expected-state"
    )
    let components = try #require(
        URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)
    )
    let queryItems = components.queryItems ?? []
    var query: [String: String] = [:]
    for queryItem in queryItems {
        query[queryItem.name] = queryItem.value
    }

    #expect(components.host == "accounts.spotify.com")
    #expect(components.path == "/authorize")
    #expect(query["client_id"] == "client-id")
    #expect(query["response_type"] == "code")
    #expect(query["redirect_uri"] == redirectURI.absoluteString)
    #expect(query["scope"] == "user-read-currently-playing")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["state"] == "expected-state")
}

@Test func callbackRequiresMatchingState() throws {
    let configuration = SpotifyConfiguration(clientID: "client-id")
    let authorization = SpotifyAuthorization(configuration: configuration)
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let request = SpotifyAuthorizationRequest(
        authorizationURL: redirectURI,
        redirectURI: redirectURI,
        state: "expected-state",
        codeVerifier: String(repeating: "a", count: 43)
    )
    let callbackURL = try #require(
        URL(string: "http://127.0.0.1:53123/callback?code=code&state=wrong-state")
    )

    do {
        _ = try authorization.authorizationCode(
            callbackURL: callbackURL,
            request: request
        )
        Issue.record("A mismatched state should fail authorization.")
    } catch let error as SpotifyError {
        #expect(error == .authorizationStateMismatch)
    }
}

@Test func callbackReturnsAuthorizationCode() throws {
    let configuration = SpotifyConfiguration(clientID: "client-id")
    let authorization = SpotifyAuthorization(configuration: configuration)
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let request = SpotifyAuthorizationRequest(
        authorizationURL: redirectURI,
        redirectURI: redirectURI,
        state: "expected-state",
        codeVerifier: String(repeating: "a", count: 43)
    )
    let callbackURL = try #require(
        URL(string: "http://127.0.0.1:53123/callback?code=authorization-code&state=expected-state")
    )

    let code = try authorization.authorizationCode(
        callbackURL: callbackURL,
        request: request
    )

    #expect(code == "authorization-code")
}

