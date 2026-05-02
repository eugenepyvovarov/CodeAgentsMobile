import XCTest
@testable import CodeAgentsMobile

final class OpenCodeChatMapperTests: XCTestCase {
    func testAccumulatorIgnoresUserEchoAndYieldsAssistantText() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        let userUpdated = try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_user","role":"user","sessionID":"ses_fixture","time":{"created":1}}}}
        """)
        let userPart = try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"text","text":"hello","id":"prt_user","messageID":"msg_user","sessionID":"ses_fixture"},"time":2}}
        """)
        XCTAssertTrue(accumulator.consume(userUpdated).isEmpty)
        XCTAssertTrue(accumulator.consume(userPart).isEmpty)

        let assistantUpdated = try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","providerID":"lmstudio","modelID":"qwen","time":{"created":3}}}}
        """)
        let assistantPart = try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"text","text":"hello from opencode","id":"prt_assistant","messageID":"msg_assistant","sessionID":"ses_fixture"},"time":4}}
        """)

        XCTAssertTrue(accumulator.consume(assistantUpdated).isEmpty)
        let chunks = accumulator.consume(assistantPart)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].content, "hello from opencode")
        XCTAssertFalse(chunks[0].isComplete)
        XCTAssertEqual(chunks[0].metadata?["runtime"] as? String, CodingAgentRuntimeKind.openCode.rawValue)
        XCTAssertEqual(chunks[0].metadata?["runtimeProvider"] as? String, "opencode:lmstudio/qwen")
    }

    func testAccumulatorCompletesOnSessionIdle() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))
        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"reasoning","text":"thinking","id":"prt_reasoning","messageID":"msg_assistant","sessionID":"ses_fixture"},"time":2}}
        """))
        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"text","text":"done","id":"prt_text","messageID":"msg_assistant","sessionID":"ses_fixture"},"time":3}}
        """))

        let chunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"session.idle","properties":{"sessionID":"ses_fixture"}}
        """))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].isComplete)
        XCTAssertEqual(chunks[0].content, "thinking\ndone")
        XCTAssertEqual(chunks[0].metadata?["opencodePartIds"] as? [String], ["prt_reasoning", "prt_text"])
    }

    func testAccumulatorYieldsToolPatchAndFilePlaceholders() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))

        let toolChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"tool","id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_fixture","tool":"bash","state":{"status":"running","input":{"command":"ls"}}},"time":2}}
        """))
        XCTAssertEqual(toolChunks.last?.content, "Tool: bash (running)\nInput: {\"command\":\"ls\"}")

        let patchChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"patch","id":"prt_patch","messageID":"msg_assistant","sessionID":"ses_fixture","path":"Sources/App.swift","text":"+ let value = true"},"time":3}}
        """))
        XCTAssertEqual(
            patchChunks.last?.content,
            "Tool: bash (running)\nInput: {\"command\":\"ls\"}\nPatch: Sources/App.swift\n+ let value = true"
        )

        let fileChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"file","id":"prt_file","messageID":"msg_assistant","sessionID":"ses_fixture","path":"README.md"},"time":4}}
        """))
        XCTAssertEqual(
            fileChunks.last?.content,
            "Tool: bash (running)\nInput: {\"command\":\"ls\"}\nPatch: Sources/App.swift\n+ let value = true\nFile: README.md"
        )
    }

    func testAccumulatorMapsPermissionUpdatedToToolPermissionChunk() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        let chunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"permission.updated","properties":{"id":"perm_fixture","type":"bash","pattern":["*.swift","*.md"],"sessionID":"ses_fixture","messageID":"msg_fixture","callID":"call_fixture","title":"Run command","metadata":{"command":"ls","path":"Sources/App.swift"},"time":{"created":1}}}
        """))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].metadata?["type"] as? String, "tool_permission")
        XCTAssertEqual(chunks[0].metadata?["permissionId"] as? String, "perm_fixture")
        XCTAssertEqual(chunks[0].metadata?["toolName"] as? String, "Run command")
        XCTAssertEqual(chunks[0].metadata?["blockedPath"] as? String, "Sources/App.swift")
        XCTAssertEqual(chunks[0].metadata?["suggestions"] as? [String], ["*.swift", "*.md"])

        let input = try XCTUnwrap(chunks[0].metadata?["input"] as? [String: Any])
        XCTAssertEqual(input["command"] as? String, "ls")
        XCTAssertEqual(input["pattern"] as? String, "*.swift, *.md")
        XCTAssertEqual(input["callID"] as? String, "call_fixture")
    }

    func testAccumulatorDropsEventsWithoutMatchingSessionID() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        let missingSessionPart = try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"part":{"type":"text","text":"cross session","id":"prt_missing","messageID":"msg_missing"},"time":1}}
        """)
        XCTAssertTrue(accumulator.consume(missingSessionPart).isEmpty)

        let otherSessionPermission = try OpenCodeEventMapper.decodeJSON("""
        {"type":"permission.updated","properties":{"id":"perm_other","type":"bash","sessionID":"ses_other","messageID":"msg_other","title":"Run command","metadata":{"command":"ls"},"time":{"created":1}}}
        """)
        XCTAssertTrue(accumulator.consume(otherSessionPermission).isEmpty)
    }

    func testHydratedMessagesMapTextPartsToRuntimeMessages() throws {
        let messages = try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data("""
        [
          {
            "info": {"role":"user","id":"msg_user","sessionID":"ses_fixture","time":{"created":1}},
            "parts": [{"type":"text","text":"hello","id":"prt_user","messageID":"msg_user","sessionID":"ses_fixture"}]
          },
          {
            "info": {"role":"assistant","id":"msg_assistant","sessionID":"ses_fixture","time":{"created":2}},
            "parts": [{"type":"text","text":"reply","id":"prt_assistant","messageID":"msg_assistant","sessionID":"ses_fixture"}]
          }
        ]
        """.utf8))

        let hydrated = OpenCodeChatMapper.hydratedMessages(from: messages)

        XCTAssertEqual(hydrated.count, 2)
        XCTAssertEqual(hydrated[0].runtimeMessageID, "msg_user")
        XCTAssertEqual(hydrated[0].role, .user)
        XCTAssertEqual(hydrated[0].text, "hello")
        XCTAssertEqual(hydrated[1].runtimeMessageID, "msg_assistant")
        XCTAssertEqual(hydrated[1].role, .assistant)
        XCTAssertEqual(hydrated[1].text, "reply")
        XCTAssertNotNil(hydrated[1].originalPayload)
    }

    func testHydratedMessagesIncludeNonTextParts() throws {
        let messages = try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data("""
        [
          {
            "info": {"role":"assistant","id":"msg_assistant","sessionID":"ses_fixture","time":{"created":1}},
            "parts": [
              {"type":"tool","id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_fixture","tool":"write","state":{"status":"completed","output":"ok"}},
              {"type":"file","id":"prt_file","messageID":"msg_assistant","sessionID":"ses_fixture","path":"README.md"}
            ]
          }
        ]
        """.utf8))

        let hydrated = OpenCodeChatMapper.hydratedMessages(from: messages)

        XCTAssertEqual(hydrated.count, 1)
        XCTAssertEqual(hydrated[0].text, "Tool: write (completed)\nOutput: ok\nFile: README.md")
        XCTAssertEqual(hydrated[0].runtimePartIDs, ["prt_tool", "prt_file"])
    }
}
