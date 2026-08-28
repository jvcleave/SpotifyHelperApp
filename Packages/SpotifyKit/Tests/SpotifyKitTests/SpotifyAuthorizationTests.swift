import Foundation
import Testing
@testable import SpotifyKit

@Test func configuredPortMustMatchAuthorizationRedirect() throws {
    let authorization = SpotifyAuthorization(configuration: SpotifyConfiguration(clientID: "client"))
    let registeredURI = try #require(URL(string: "http://127.0.0.1:8888/callback"))
    #expect(try authorization.makeRequest(redirectURI: registeredURI).redirectURI == registeredURI)
    let differentURI = try #require(URL(string: "http://127.0.0.1:8889/callback"))
    #expect(throws: SpotifyError.invalidConfiguration("The callback port must match the registered Spotify redirect port.")) {
        try authorization.makeRequest(redirectURI: differentURI)
    }
}

@Test func generatedVerifierAndStateAreURLSafeAndUnique() throws {
    let authorization = SpotifyAuthorization(configuration: SpotifyConfiguration(
        clientID: "client",
        redirectPort: 53123
    ))
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let first = try authorization.makeRequest(redirectURI: redirectURI)
    let second = try authorization.makeRequest(redirectURI: redirectURI)
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    #expect((43...128).contains(first.codeVerifier.count))
    #expect(first.codeVerifier.rangeOfCharacter(from: allowed.inverted) == nil)
    #expect(!first.state.isEmpty)
    #expect(first.state.rangeOfCharacter(from: allowed.inverted) == nil)
    #expect(first.codeVerifier != second.codeVerifier)
    #expect(first.state != second.state)
}

@Test(arguments: [
    ("http://127.0.0.1:53123/callback?error=access_denied&state=expected-state", SpotifyError.authorizationDenied("access_denied")),
    ("http://127.0.0.1:53123/callback?error=access_denied&state=wrong", .authorizationStateMismatch),
    ("http://127.0.0.1:53123/callback?state=expected-state", .invalidAuthorizationCallback),
    ("http://127.0.0.1:53123/callback?code=one&code=two&state=expected-state", .invalidAuthorizationCallback),
    ("http://127.0.0.1:53123/callback?code=one&state=expected-state&state=expected-state", .invalidAuthorizationCallback),
    ("http://127.0.0.1:53124/callback?code=one&state=expected-state", .invalidAuthorizationCallback),
    ("http://127.0.0.1:53123/other?code=one&state=expected-state", .invalidAuthorizationCallback)
])
func invalidOrDeniedCallbackIsRejected(
    callback: String,
    expectedError: SpotifyError
) throws {
    let authorization = SpotifyAuthorization(configuration: SpotifyConfiguration(
        clientID: "client",
        redirectPort: 53123
    ))
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let request = SpotifyAuthorizationRequest(
        authorizationURL: redirectURI,
        redirectURI: redirectURI,
        state: "expected-state",
        codeVerifier: String(
            repeating: "a",
            count: 43
        )
    )
    let callbackURL = try #require(URL(string: callback))
    #expect(throws: expectedError) {
        try authorization.authorizationCode(
            callbackURL: callbackURL,
            request: request
        )
    }
}

@Test func pkceChallengeMatchesRFC7636Fixture() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    let challenge = SpotifyAuthorization.codeChallenge(codeVerifier: verifier)

    #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func authorizationRequestContainsMinimumScopeAndPKCEValues() throws {
    let configuration = SpotifyConfiguration(
        clientID: "client-id",
        redirectPort: 53123
    )
    let authorization = SpotifyAuthorization(configuration: configuration)
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let verifier = String(
        repeating: "a",
        count: 43
    )

    let request = try authorization.makeRequest(
        redirectURI: redirectURI,
        codeVerifier: verifier,
        state: "expected-state"
    )
    let components = try #require(
        URLComponents(
            url: request.authorizationURL,
            resolvingAgainstBaseURL: false
        )
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
    let configuration = SpotifyConfiguration(
        clientID: "client-id",
        redirectPort: 53123
    )
    let authorization = SpotifyAuthorization(configuration: configuration)
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let request = SpotifyAuthorizationRequest(
        authorizationURL: redirectURI,
        redirectURI: redirectURI,
        state: "expected-state",
        codeVerifier: String(
            repeating: "a",
            count: 43
        )
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
    let configuration = SpotifyConfiguration(
        clientID: "client-id",
        redirectPort: 53123
    )
    let authorization = SpotifyAuthorization(configuration: configuration)
    let redirectURI = try #require(URL(string: "http://127.0.0.1:53123/callback"))
    let request = SpotifyAuthorizationRequest(
        authorizationURL: redirectURI,
        redirectURI: redirectURI,
        state: "expected-state",
        codeVerifier: String(
            repeating: "a",
            count: 43
        )
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
