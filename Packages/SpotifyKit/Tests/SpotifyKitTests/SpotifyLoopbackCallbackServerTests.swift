import Darwin
import Foundation
import Testing
@testable import SpotifyKit

@Test func loopbackServerReceivesCallbackAndReturnsBrowserMessage() async throws {
    let server = SpotifyLoopbackCallbackServer()
    let redirectURI = try await server.start()
    var callbackComponents = try #require(
        URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
    )
    callbackComponents.queryItems = [
        URLQueryItem(name: "code", value: "authorization-code"),
        URLQueryItem(name: "state", value: "expected-state")
    ]
    let callbackRequestURL = try #require(callbackComponents.url)

    async let receivedCallback = server.waitForCallback()
    #expect(await server.isRunning)
    let responseData = try sendHTTPRequest(url: callbackRequestURL)
    let callbackURL = try await receivedCallback
    await server.stop()

    let browserMessage = try #require(String(data: responseData, encoding: .utf8))
    #expect(browserMessage.contains("HTTP/1.1 200 OK"))
    #expect(browserMessage.contains("\r\n\r\nSpotify response received"))
    #expect(callbackURL == callbackRequestURL)
    let responseParts = browserMessage.components(separatedBy: "\r\n\r\n")
    try #require(responseParts.count == 2)
    #expect(responseParts[0].contains("Content-Length: \(responseParts[1].utf8.count)"))
}

@Test func loopbackResponseWorksWithURLSession() async throws {
    let server = SpotifyLoopbackCallbackServer()
    let redirectURI = try await server.start()
    let session = URLSession(configuration: .ephemeral)
    let (data, response) = try await session.data(from: redirectURI)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self).contains("Spotify response received"))
    #expect(try await server.waitForCallback() == redirectURI)
    await server.stop()
}

@Test func loopbackIgnoresFaviconAndReadsFragmentedCallback() async throws {
    let server = SpotifyLoopbackCallbackServer()
    let redirectURI = try await server.start()
    let faviconURL = redirectURI.deletingLastPathComponent().appendingPathComponent("favicon.ico")
    let faviconResponse = try sendHTTPRequest(url: faviconURL)
    #expect(String(decoding: faviconResponse, as: UTF8.self).contains("404 Not Found"))
    #expect(await server.isRunning)
    _ = try sendHTTPRequest(
        url: redirectURI,
        fragmented: true
    )
    #expect(try await server.waitForCallback().path == "/callback")
    await server.stop()
}

@Test func stoppedLoopbackDoesNotHangALaterWait() async throws {
    let server = SpotifyLoopbackCallbackServer()
    _ = try await server.start()
    await server.stop()
    await server.stop()
    await #expect(throws: CancellationError.self) {
        try await server.waitForCallback()
    }
    #expect(await !server.isRunning)
}

@Test func callbackCancellationClosesListener() async throws {
    let server = SpotifyLoopbackCallbackServer()
    _ = try await server.start()
    let callbackTask = Task { try await server.waitForCallback() }
    callbackTask.cancel()
    await #expect(throws: CancellationError.self) {
        try await callbackTask.value
    }
    #expect(await !server.isRunning)
}

@Test func callbackDeadlineClosesListener() async throws {
    let server = SpotifyLoopbackCallbackServer(timeout: .milliseconds(100))
    _ = try await server.start()
    await #expect(throws: SpotifyError.self) {
        try await server.waitForCallback()
    }
    #expect(await !server.isRunning)
    await server.stop()
}

private func sendHTTPRequest(
    url: URL,
    fragmented: Bool = false
) throws -> Data {
    let port = try #require(url.port)
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    try #require(socketDescriptor >= 0)
    defer {
        close(socketDescriptor)
    }
    var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(
        socketDescriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &receiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)
    )

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    let conversionResult = "127.0.0.1".withCString { hostAddress in
        inet_pton(AF_INET, hostAddress, &address.sin_addr)
    }
    #expect(conversionResult == 1)

    let connectionResult = withUnsafePointer(to: &address) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            connect(
                socketDescriptor,
                socketAddress,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    try #require(connectionResult == 0)

    let requestTarget = url.path + "?" + (url.query ?? "")
    let request = "GET \(requestTarget) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
    let requestData = Data(request.utf8)
    let chunks = fragmented ? [requestData.prefix(7), requestData.dropFirst(7)] : [requestData[...]]
    for chunk in chunks {
        let writtenByteCount = chunk.withUnsafeBytes { requestBytes in
            Darwin.write(
                socketDescriptor,
                requestBytes.baseAddress,
                requestBytes.count
            )
        }
        try #require(writtenByteCount == chunk.count)
    }

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let readByteCount = Darwin.read(
            socketDescriptor,
            &buffer,
            buffer.count
        )
        if readByteCount <= 0 {
            break
        }
        responseData.append(buffer, count: readByteCount)
    }
    return responseData
}
