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
}

private final class FakeSSHSession: SSHSession {
    private let processHandle: FakeProcessHandle
    private(set) var openedHost: String?
    private(set) var openedPort: Int?

    var sentInput: String {
        processHandle.sentInput
    }

    init(responseChunks: [String]) {
        self.processHandle = FakeProcessHandle(responseChunks: responseChunks)
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
    private(set) var sentInput = ""
    private(set) var terminated = false

    var isRunning: Bool {
        !terminated
    }

    init(responseChunks: [String]) {
        self.responseChunks = responseChunks
    }

    func sendInput(_ text: String) async throws {
        sentInput += text
    }

    func readOutput() async throws -> String {
        responseChunks.joined()
    }

    func outputStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in responseChunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func terminate() {
        terminated = true
    }
}
