import XCTest
@testable import CodeAgentsMobile

final class OpenCodeSessionAPITests: XCTestCase {
    func testCreateSessionPostsPayloadAndDecodesSession() async throws {
        let response = try httpResponse(status: "200 OK", body: loadOpenCodeFixture(named: "session_create.json"))
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let created = try await client.createSession(
            sshSession: sshSession,
            parentID: "parent_fixture",
            title: "MobileCode OpenCode fixture",
            directory: "/workspace/MobileCode"
        )

        XCTAssertEqual(created.id, "ses_fixture")
        XCTAssertEqual(created.version, "1.14.21")
        XCTAssertTrue(sshSession.sentInput.contains("POST /session?directory=/workspace/MobileCode HTTP/1.1"))

        let body = try sshSession.sentJSONObject()
        XCTAssertEqual(body["parentID"] as? String, "parent_fixture")
        XCTAssertEqual(body["title"] as? String, "MobileCode OpenCode fixture")
    }

    func testSessionStatusDecodesEmptyStatusMap() async throws {
        let response = try httpResponse(status: "200 OK", body: loadOpenCodeFixture(named: "session_status_empty.json"))
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let statuses = try await client.sessionStatus(sshSession: sshSession)

        XCTAssertTrue(statuses.isEmpty)
        XCTAssertTrue(sshSession.sentInput.contains("GET /session/status HTTP/1.1"))
    }

    func testSessionMessagesHydratesFixture() async throws {
        let response = try httpResponse(status: "200 OK", body: loadOpenCodeFixture(named: "session_messages_text.json"))
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let messages = try await client.sessionMessages(
            sshSession: sshSession,
            sessionID: "ses_fixture",
            directory: "/workspace/MobileCode",
            limit: 50
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].info.id, "msg_text_fixture")
        XCTAssertTrue(sshSession.sentInput.contains(
            "GET /session/ses_fixture/message?directory=/workspace/MobileCode&limit=50 HTTP/1.1"
        ))

        guard case .text(let part) = try XCTUnwrap(messages[0].parts.first) else {
            return XCTFail("Expected text part")
        }
        XCTAssertEqual(part.id, "prt_text_fixture")
        XCTAssertEqual(part.text, "MobileCode fixture user message")
    }

    func testSessionMessageDecodesSingleMessage() async throws {
        let body = """
        {"info":{"role":"user","id":"msg_fixture","sessionID":"ses_fixture","time":{"created":1}},"parts":[{"type":"text","text":"hello","id":"prt_fixture","sessionID":"ses_fixture","messageID":"msg_fixture"}]}
        """
        let response = try httpResponse(status: "200 OK", body: body)
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let message = try await client.sessionMessage(
            sshSession: sshSession,
            sessionID: "ses/fixture",
            messageID: "msg fixture"
        )

        XCTAssertEqual(message.info.id, "msg_fixture")
        XCTAssertTrue(sshSession.sentInput.contains("GET /session/ses%2Ffixture/message/msg%20fixture HTTP/1.1"))
    }

    func testPromptAsyncEncodesPromptPayload() async throws {
        let response = try httpResponse(status: "204 No Content", body: "")
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()
        let payload = OpenCodePromptPayload(
            messageID: "msg_fixture",
            model: OpenCodePromptModel(providerID: "lmstudio", modelID: "qwen/qwen3-coder-next"),
            agent: "build",
            noReply: true,
            system: "system fixture",
            tools: ["bash": true, "write": false],
            parts: [
                .text("hello", id: "prt_text"),
                .file(id: "prt_file", mime: "text/plain", filename: "fixture.txt", url: "file:///tmp/fixture.txt"),
                .agent(id: "prt_agent", name: "reviewer"),
                .subtask(id: "prt_subtask", prompt: "check", description: "Review fixture", agent: "build")
            ]
        )

        let result = try await client.promptAsync(
            sshSession: sshSession,
            sessionID: "ses/fixture",
            payload: payload,
            directory: "/workspace/MobileCode"
        )

        XCTAssertEqual(result.statusCode, 204)
        XCTAssertTrue(sshSession.sentInput.contains(
            "POST /session/ses%2Ffixture/prompt_async?directory=/workspace/MobileCode HTTP/1.1"
        ))

        let body = try sshSession.sentJSONObject()
        XCTAssertEqual(body["messageID"] as? String, "msg_fixture")
        XCTAssertEqual(body["agent"] as? String, "build")
        XCTAssertEqual(body["noReply"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "system fixture")
        XCTAssertEqual((body["tools"] as? [String: Bool])?["bash"], true)
        XCTAssertEqual((body["model"] as? [String: String])?["providerID"], "lmstudio")

        let parts = try XCTUnwrap(body["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "file", "agent", "subtask"])
        XCTAssertEqual(parts[0]["text"] as? String, "hello")
        XCTAssertEqual(parts[1]["url"] as? String, "file:///tmp/fixture.txt")
        XCTAssertEqual(parts[2]["name"] as? String, "reviewer")
        XCTAssertEqual(parts[3]["prompt"] as? String, "check")
    }

    func testSendMessageDecodesAssistantMessage() async throws {
        let body = """
        {"info":{"role":"assistant","id":"msg_assistant_fixture","sessionID":"ses_fixture","time":{"created":1},"modelID":"model_fixture","providerID":"provider_fixture"},"parts":[{"type":"text","text":"done","id":"prt_fixture","sessionID":"ses_fixture","messageID":"msg_assistant_fixture"}]}
        """
        let response = try httpResponse(status: "200 OK", body: body)
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let message = try await client.sendMessage(
            sshSession: sshSession,
            sessionID: "ses_fixture",
            payload: OpenCodePromptPayload(parts: [.text("hello")])
        )

        XCTAssertEqual(message.info.id, "msg_assistant_fixture")
        XCTAssertEqual(message.info.role, "assistant")
        XCTAssertTrue(sshSession.sentInput.contains("POST /session/ses_fixture/message HTTP/1.1"))
    }

    func testAbortSessionDecodesBool() async throws {
        let response = try httpResponse(status: "200 OK", body: "true")
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let aborted = try await client.abortSession(sshSession: sshSession, sessionID: "ses_fixture")

        XCTAssertTrue(aborted)
        XCTAssertTrue(sshSession.sentInput.contains("POST /session/ses_fixture/abort HTTP/1.1"))
    }

    func testReplyPermissionPostsResponsePayload() async throws {
        let response = try httpResponse(status: "204 No Content", body: "")
        let sshSession = SessionAPIFakeSSHSession(responseChunks: [response])
        let client = OpenCodeClient()

        let result = try await client.replyPermission(
            sshSession: sshSession,
            sessionID: "ses/fixture",
            permissionID: "perm fixture",
            response: "always",
            directory: "/workspace/MobileCode"
        )

        XCTAssertEqual(result.statusCode, 204)
        XCTAssertTrue(sshSession.sentInput.contains(
            "POST /session/ses%2Ffixture/permissions/perm%20fixture?directory=/workspace/MobileCode HTTP/1.1"
        ))
        let body = try sshSession.sentJSONObject()
        XCTAssertEqual(body["response"] as? String, "always")
    }

    func testHydrationDiffComparesMessageAndPartIDs() throws {
        let remote = try JSONDecoder().decode(
            [OpenCodeSessionMessage].self,
            from: Data(loadOpenCodeFixture(named: "session_messages_text.json").utf8)
        )
        let local = OpenCodeHydrationState(messageIDs: ["old_message"], partIDs: ["old_part"])

        let diff = OpenCodeHydrationDiffer.diff(local: local, remoteMessages: remote)

        XCTAssertTrue(diff.hasChanges)
        XCTAssertEqual(diff.addedMessageIDs, ["msg_text_fixture"])
        XCTAssertEqual(diff.removedMessageIDs, ["old_message"])
        XCTAssertEqual(diff.addedPartIDs, ["prt_text_fixture"])
        XCTAssertEqual(diff.removedPartIDs, ["old_part"])
    }

    private func httpResponse(status: String, body: String) throws -> String {
        let length = body.data(using: .utf8)?.count ?? 0
        return [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Content-Length: \(length)",
            "",
            body
        ].joined(separator: "\r\n")
    }

    private func loadOpenCodeFixture(named name: String) throws -> String {
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("OpenCode")
            .appendingPathComponent(name)
        return try String(contentsOf: fixturesURL, encoding: .utf8)
    }
}

private final class SessionAPIFakeSSHSession: SSHSession {
    private let processHandle: SessionAPIFakeProcessHandle
    private(set) var openedHost: String?
    private(set) var openedPort: Int?

    var sentInput: String {
        processHandle.sentInput
    }

    init(responseChunks: [String]) {
        self.processHandle = SessionAPIFakeProcessHandle(responseChunks: responseChunks)
    }

    func sentJSONObject() throws -> [String: Any] {
        let body = sentInput.components(separatedBy: "\r\n\r\n").last ?? ""
        let data = Data(body.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
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

private final class SessionAPIFakeProcessHandle: ProcessHandle {
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
