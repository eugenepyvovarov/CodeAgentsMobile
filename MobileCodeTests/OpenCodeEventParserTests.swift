import XCTest
@testable import CodeAgentsMobile

final class OpenCodeEventParserTests: XCTestCase {
    func testSSEParserParsesConnectedAndHeartbeatFixture() throws {
        let fixture = try loadOpenCodeFixture(named: "event_connected_heartbeat.sse")
        let parser = OpenCodeSSEStreamParser()

        let midpoint = fixture.index(fixture.startIndex, offsetBy: fixture.count / 2)
        let events = parser.consume(String(fixture[..<midpoint]))
            + parser.consume(String(fixture[midpoint...]))
            + parser.finish()

        XCTAssertEqual(events.count, 2)

        guard case .serverConnected = try OpenCodeEventMapper.decode(events[0]) else {
            return XCTFail("Expected server.connected")
        }
        guard case .serverHeartbeat = try OpenCodeEventMapper.decode(events[1]) else {
            return XCTFail("Expected server.heartbeat")
        }
    }

    func testMessageTextFixtureMapsMessageAndPartEvents() throws {
        let events = try parseFixtureEvents(named: "event_message_text.sse")

        let messageEvent = try XCTUnwrap(events.compactMap { event -> OpenCodeMessageUpdatedProperties? in
            guard case .messageUpdated(let properties, _) = event else { return nil }
            return properties
        }.first)
        XCTAssertEqual(messageEvent.sessionID, "ses_fixture")
        XCTAssertEqual(messageEvent.info.id, "msg_stream_fixture")
        XCTAssertEqual(messageEvent.info.role, "user")

        let partEvent = try XCTUnwrap(events.compactMap { event -> OpenCodeMessagePartUpdatedProperties? in
            guard case .messagePartUpdated(let properties, _) = event else { return nil }
            return properties
        }.first)
        XCTAssertEqual(partEvent.sessionID, "ses_fixture")
        XCTAssertEqual(partEvent.part.payload.id, "prt_stream_fixture")
        XCTAssertEqual(partEvent.part.payload.messageID, "msg_stream_fixture")

        guard case .text(let payload) = partEvent.part else {
            return XCTFail("Expected text part")
        }
        XCTAssertEqual(payload.text, "MobileCode fixture streamed event")

        let sessionEvent = try XCTUnwrap(events.compactMap { event -> OpenCodeSessionInfoProperties? in
            guard case .sessionUpdated(let properties, _) = event else { return nil }
            return properties
        }.first)
        XCTAssertEqual(sessionEvent.info?.version, "1.14.21")
    }

    func testPromptAbortFixtureMapsSessionStatusAndError() throws {
        let events = try parseFixtureEvents(named: "event_prompt_async_abort.sse")

        let statuses = events.compactMap { event -> String? in
            guard case .sessionStatus(let properties, _) = event else { return nil }
            return properties.status.type
        }
        XCTAssertEqual(statuses, ["busy", "idle"])

        let error = try XCTUnwrap(events.compactMap { event -> OpenCodeSessionErrorProperties? in
            guard case .sessionError(let properties, _) = event else { return nil }
            return properties
        }.first)
        XCTAssertEqual(error.sessionID, "ses_fixture")
        XCTAssertEqual(error.error.name, "MessageAbortedError")
        XCTAssertEqual(error.error.data?["message"]?.value as? String, "Aborted")

        XCTAssertTrue(events.contains { event in
            guard case .sessionIdle(let properties, _) = event else { return false }
            return properties.sessionID == "ses_fixture"
        })
    }

    func testGlobalEventPayloadMapsWithContext() throws {
        let event = try OpenCodeEventMapper.decodeJSON("""
        {"directory":"/workspace/MobileCode","project":"project_fixture","workspace":"workspace_fixture","payload":{"type":"server.connected","properties":{}}}
        """)

        guard case .serverConnected(let rawEvent) = event else {
            return XCTFail("Expected server.connected")
        }
        XCTAssertEqual(rawEvent.context?.directory, "/workspace/MobileCode")
        XCTAssertEqual(rawEvent.context?.project, "project_fixture")
        XCTAssertEqual(rawEvent.context?.workspace, "workspace_fixture")
    }

    func testParserHandlesMetadataCommentsAndMultilineData() {
        let parser = OpenCodeSSEStreamParser()
        let events = parser.consume("""
        : ignored
        id: evt_fixture
        event: message
        retry: 1000
        data: {"type":"unknown.fixture",
        data: "properties":{"value":1}}

        """) + parser.finish()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "evt_fixture")
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].retry, 1000)
        XCTAssertEqual(events[0].data, """
        {"type":"unknown.fixture",
        "properties":{"value":1}}
        """)
    }

    func testKnownMessagePartTypesDecode() throws {
        let partTypes = [
            "text",
            "reasoning",
            "file",
            "tool",
            "step-start",
            "step-finish",
            "snapshot",
            "patch",
            "agent",
            "subtask",
            "retry",
            "compaction"
        ]

        for partType in partTypes {
            let event = try OpenCodeEventMapper.decodeJSON("""
            {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"\(partType)","id":"prt_fixture","messageID":"msg_fixture","sessionID":"ses_fixture","text":"hello","state":"completed"},"time":1}}
            """)

            guard case .messagePartUpdated(let properties, _) = event else {
                return XCTFail("Expected message.part.updated for \(partType)")
            }
            XCTAssertEqual(properties.part.payload.type, partType)
            XCTAssertEqual(properties.part.payload.id, "prt_fixture")
        }
    }

    func testPermissionEventsDecode() throws {
        let event = try OpenCodeEventMapper.decodeJSON("""
        {"type":"permission.updated","properties":{"id":"perm_fixture","type":"bash","pattern":"*","sessionID":"ses_fixture","messageID":"msg_fixture","callID":"call_fixture","title":"Run command","metadata":{"command":"ls"},"time":{"created":1}}}
        """)

        guard case .permissionUpdated(let properties, _) = event else {
            return XCTFail("Expected permission.updated")
        }
        XCTAssertEqual(properties.id, "perm_fixture")
        XCTAssertEqual(properties.sessionID, "ses_fixture")
        XCTAssertEqual(properties.pattern?.values, ["*"])
        XCTAssertEqual(properties.metadata?["command"]?.value as? String, "ls")
    }

    func testPermissionPatternArrayAndReplyDecode() throws {
        let updated = try OpenCodeEventMapper.decodeJSON("""
        {"type":"permission.updated","properties":{"id":"perm_fixture","type":"edit","pattern":["*.swift","*.md"],"sessionID":"ses_fixture","messageID":"msg_fixture","title":"Edit files","metadata":{},"time":{"created":1}}}
        """)
        guard case .permissionUpdated(let updatedProperties, _) = updated else {
            return XCTFail("Expected permission.updated")
        }
        XCTAssertEqual(updatedProperties.pattern?.values, ["*.swift", "*.md"])

        let replied = try OpenCodeEventMapper.decodeJSON("""
        {"type":"permission.replied","properties":{"sessionID":"ses_fixture","permissionID":"perm_fixture","response":"once"}}
        """)
        guard case .permissionReplied(let repliedProperties, _) = replied else {
            return XCTFail("Expected permission.replied")
        }
        XCTAssertEqual(repliedProperties.permissionID, "perm_fixture")
        XCTAssertEqual(repliedProperties.response, "once")
    }

    func testQuestionEventsDecode() throws {
        let asked = try OpenCodeEventMapper.decodeJSON("""
        {"type":"question.asked","properties":{"id":"question_fixture","sessionID":"ses_fixture","questions":[{"header":"Scope","question":"Which setup should I use?","options":[{"label":"Default","description":"Use the standard setup."}],"multiple":false,"custom":true}],"tool":{"messageID":"msg_fixture","callID":"call_fixture"}}}
        """)

        guard case .questionAsked(let request, _) = asked else {
            return XCTFail("Expected question.asked")
        }
        XCTAssertEqual(request.id, "question_fixture")
        XCTAssertEqual(request.sessionID, "ses_fixture")
        XCTAssertEqual(request.questions.first?.header, "Scope")
        XCTAssertEqual(request.questions.first?.options.first?.label, "Default")
        XCTAssertEqual(request.tool?.callID, "call_fixture")

        let replied = try OpenCodeEventMapper.decodeJSON("""
        {"type":"question.replied","properties":{"sessionID":"ses_fixture","requestID":"question_fixture","answers":[["Default"]]}}
        """)
        guard case .questionReplied(let reply, _) = replied else {
            return XCTFail("Expected question.replied")
        }
        XCTAssertEqual(reply.requestID, "question_fixture")
        XCTAssertEqual(reply.answers, [["Default"]])

        let rejected = try OpenCodeEventMapper.decodeJSON("""
        {"type":"question.rejected","properties":{"sessionID":"ses_fixture","requestID":"question_fixture"}}
        """)
        guard case .questionRejected(let rejection, _) = rejected else {
            return XCTFail("Expected question.rejected")
        }
        XCTAssertEqual(rejection.requestID, "question_fixture")
    }

    private func parseFixtureEvents(named name: String) throws -> [OpenCodeEvent] {
        let fixture = try loadOpenCodeFixture(named: name)
        let parser = OpenCodeSSEStreamParser()
        let sseEvents = parser.consume(fixture) + parser.finish()
        return try sseEvents.map(OpenCodeEventMapper.decode)
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
