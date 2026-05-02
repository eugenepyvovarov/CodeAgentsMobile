import XCTest
@testable import CodeAgentsMobile

final class OpenCodeClientTests: XCTestCase {
    func testHealthRequestDecodesResponse() async throws {
        let response = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: 36",
            "",
            "{\"healthy\":true,\"version\":\"1.14.21\"}"
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let health = try await client.health(session: session)

        XCTAssertEqual(health, OpenCodeHealth(healthy: true, version: "1.14.21"))
        XCTAssertEqual(session.openedHost, "127.0.0.1")
        XCTAssertEqual(session.openedPort, 4096)
        XCTAssertTrue(session.sentInput.contains("GET /global/health HTTP/1.1"))
        XCTAssertTrue(session.sentInput.contains("Accept: application/json"))
        XCTAssertTrue(session.sentInput.contains("Connection: close"))
    }

    func testRequestAddsBasicAuthWhenPasswordIsConfigured() async throws {
        let response = [
            "HTTP/1.1 200 OK",
            "Content-Length: 2",
            "",
            "{}"
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let configuration = OpenCodeClientConfiguration(username: "custom", password: "secret")
        let client = OpenCodeClient(configuration: configuration)

        _ = try await client.request(session: session, method: .get, path: "/session")

        XCTAssertTrue(session.sentInput.contains("Authorization: Basic Y3VzdG9tOnNlY3JldA=="))
    }

    func testRequestEncodesJSONBody() async throws {
        let response = [
            "HTTP/1.1 204 No Content",
            "Content-Length: 0",
            "",
            ""
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let result = try await client.request(
            session: session,
            method: .post,
            path: "/session/ses_fixture/prompt_async",
            body: "{\"parts\":[]}"
        )

        XCTAssertEqual(result.statusCode, 204)
        XCTAssertTrue(session.sentInput.contains("POST /session/ses_fixture/prompt_async HTTP/1.1"))
        XCTAssertTrue(session.sentInput.contains("Content-Type: application/json"))
        XCTAssertTrue(session.sentInput.contains("Content-Length: 12"))
        XCTAssertTrue(session.sentInput.hasSuffix("\r\n\r\n{\"parts\":[]}"))
    }

    func testChunkedResponseDecodesBody() async throws {
        let response = [
            "HTTP/1.1 200 OK",
            "Transfer-Encoding: chunked",
            "",
            "5",
            "hello",
            "0",
            "",
            ""
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let result = try await client.request(session: session, method: .get, path: "/mcp")

        XCTAssertEqual(result.body, "hello")
    }

    func testChunkedResponseUsesByteSizedChunks() async throws {
        let response = [
            "HTTP/1.1 200 OK",
            "Transfer-Encoding: chunked",
            "",
            "5",
            "caf\u{00E9}",
            "0",
            "",
            ""
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let result = try await client.request(session: session, method: .get, path: "/mcp")

        XCTAssertEqual(result.body, "caf\u{00E9}")
    }

    func testHTTPErrorThrowsStatusAndBody() async throws {
        let response = [
            "HTTP/1.1 404 Not Found",
            "Content-Type: application/json",
            "Content-Length: 19",
            "",
            "{\"error\":\"missing\"}"
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        do {
            _ = try await client.request(session: session, method: .get, path: "/missing")
            XCTFail("Expected HTTP error")
        } catch let error as OpenCodeClientError {
            XCTAssertEqual(error, .httpError(status: 404, body: "{\"error\":\"missing\"}"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestTimesOutAndTerminatesHandleWhenResponseDoesNotFinish() async throws {
        let response = [
            "HTTP/1.1 200 OK",
            "Content-Length: 2",
            "",
            "{}"
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response], chunkDelayNanoseconds: 200_000_000)
        let configuration = OpenCodeClientConfiguration(requestTimeoutSeconds: 0.01)
        let client = OpenCodeClient(configuration: configuration)

        do {
            _ = try await client.request(session: session, method: .get, path: "/session")
            XCTFail("Expected timeout")
        } catch let error as OpenCodeClientError {
            guard case .requestTimedOut(let seconds) = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
            XCTAssertEqual(seconds, 0.01, accuracy: 0.001)
            XCTAssertTrue(session.didTerminateProcess)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEventStreamDecodesChunkedSSE() async throws {
        let body = """
        data: {"type":"server.connected","properties":{}}

        data: {"type":"session.status","properties":{"sessionID":"ses_fixture","status":{"type":"idle"}}}

        """
        let response = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Transfer-Encoding: chunked",
            "",
            chunkedBody(body)
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        var events: [OpenCodeEvent] = []
        for try await event in client.streamEvents(session: session) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        guard case .serverConnected = events[0] else {
            return XCTFail("Expected server.connected")
        }
        guard case .sessionStatus(let properties, _) = events[1] else {
            return XCTFail("Expected session.status")
        }
        XCTAssertEqual(properties.sessionID, "ses_fixture")
        XCTAssertEqual(properties.status.type, "idle")
        XCTAssertTrue(session.sentInput.contains("GET /event HTTP/1.1"))
        XCTAssertTrue(session.sentInput.contains("Accept: text/event-stream"))
        XCTAssertFalse(session.sentInput.contains("Accept: application/json"))
    }

    func testEventStreamCanUseScopedDirectoryPath() async throws {
        let body = """
        data: {"type":"server.connected","properties":{}}

        """
        let response = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Transfer-Encoding: chunked",
            "",
            chunkedBody(body)
        ].joined(separator: "\r\n")
        let session = FakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()
        let path = OpenCodeSessionPath.path("/event", directory: "/workspace/Mobile Code")

        var events: [OpenCodeEvent] = []
        for try await event in client.streamEvents(session: session, path: path) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(session.sentInput.contains("GET /event?directory=/workspace/Mobile%20Code HTTP/1.1"))
    }

    private func chunkedBody(_ body: String) -> String {
        let size = String(body.utf8.count, radix: 16)
        return "\(size)\r\n\(body)\r\n0\r\n\r\n"
    }
}

private final class FakeSSHSession: SSHSession {
    private let processHandle: FakeProcessHandle
    private(set) var openedHost: String?
    private(set) var openedPort: Int?

    var sentInput: String {
        processHandle.sentInput
    }

    var didTerminateProcess: Bool {
        processHandle.terminated
    }

    init(responseChunks: [String], chunkDelayNanoseconds: UInt64? = nil) {
        self.processHandle = FakeProcessHandle(
            responseChunks: responseChunks,
            chunkDelayNanoseconds: chunkDelayNanoseconds
        )
    }

    func execute(_ command: String) async throws -> String {
        throw SSHError.commandFailed("Not implemented")
    }

    func executeRaw(_ command: String) async throws -> String {
        throw SSHError.commandFailed("Not implemented")
    }

    func startProcess(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func startProcessRaw(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> ProcessHandle {
        openedHost = targetHost
        openedPort = targetPort
        return processHandle
    }

    func uploadFile(localPath: URL, remotePath: String) async throws {
        throw SSHError.commandFailed("Not implemented")
    }

    func downloadFile(remotePath: String, localPath: URL) async throws {
        throw SSHError.commandFailed("Not implemented")
    }

    func readFile(_ remotePath: String) async throws -> String {
        throw SSHError.commandFailed("Not implemented")
    }

    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        throw SSHError.commandFailed("Not implemented")
    }

    func disconnect() {}
}

private final class FakeProcessHandle: ProcessHandle {
    private let responseChunks: [String]
    private let chunkDelayNanoseconds: UInt64?
    private(set) var sentInput = ""
    private(set) var terminated = false

    var isRunning: Bool {
        !terminated
    }

    init(responseChunks: [String], chunkDelayNanoseconds: UInt64? = nil) {
        self.responseChunks = responseChunks
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    func sendInput(_ text: String) async throws {
        sentInput += text
    }

    func readOutput() async throws -> String {
        responseChunks.joined()
    }

    func outputStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let chunks = responseChunks
            let delay = chunkDelayNanoseconds
            Task {
                for chunk in chunks {
                    if let delay {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    func terminate() {
        terminated = true
    }
}
