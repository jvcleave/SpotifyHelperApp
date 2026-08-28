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
    #expect(browserMessage.contains("Spotify is connected"))
    #expect(callbackURL == callbackRequestURL)
}

private func sendHTTPRequest(url: URL) throws -> Data {
    let port = try #require(url.port)
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    #expect(socketDescriptor >= 0)
    defer {
        close(socketDescriptor)
    }

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
    #expect(connectionResult == 0)

    let requestTarget = url.path + "?" + (url.query ?? "")
    let request = "GET \(requestTarget) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
    let requestData = Data(request.utf8)
    let writtenByteCount = requestData.withUnsafeBytes { requestBytes in
        Darwin.write(
            socketDescriptor,
            requestBytes.baseAddress,
            requestBytes.count
        )
    }
    #expect(writtenByteCount == requestData.count)

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
