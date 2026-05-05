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
        XCTAssertEqual(chunks[0].content, "done")
        XCTAssertEqual(chunks[0].metadata?["opencodePartIds"] as? [String], ["prt_reasoning", "prt_text"])

        let original = try XCTUnwrap(chunks[0].metadata?["originalJSON"] as? String)
        let originalData = try XCTUnwrap(original.data(using: .utf8))
        let structured = try JSONDecoder().decode(StructuredMessageContent.self, from: originalData)
        XCTAssertEqual(structured.type, "assistant")
    }

    func testAccumulatorDoesNotCompleteOnEarlyIdleBeforeAnswerText() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))
        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"reasoning","text":"thinking","id":"prt_reasoning","messageID":"msg_assistant","sessionID":"ses_fixture"},"time":2}}
        """))

        let idleChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"session.status","properties":{"sessionID":"ses_fixture","status":{"type":"idle"}}}
        """))

        XCTAssertTrue(idleChunks.isEmpty)

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1,"completed":4}}}}
        """))
        let textChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"text","text":"late answer","id":"prt_text","messageID":"msg_assistant","sessionID":"ses_fixture"},"time":5}}
        """))

        XCTAssertEqual(textChunks.last?.content, "late answer")
        XCTAssertEqual(textChunks.last?.isComplete, true)
    }

    func testAccumulatorBuildsAnswerFromPartDeltas() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))

        let firstDelta = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.delta","properties":{"sessionID":"ses_fixture","messageID":"msg_assistant","partID":"prt_text","delta":"Hello"}}
        """))
        let secondDelta = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.delta","properties":{"sessionID":"ses_fixture","messageID":"msg_assistant","partID":"prt_text","delta":" from OpenCode"}}
        """))

        XCTAssertEqual(firstDelta.last?.content, "Hello")
        XCTAssertEqual(secondDelta.last?.content, "Hello from OpenCode")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1,"completed":4}}}}
        """))
        let idleChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"session.status","properties":{"sessionID":"ses_fixture","status":{"type":"idle"}}}
        """))

        XCTAssertEqual(idleChunks.last?.content, "Hello from OpenCode")
        XCTAssertEqual(idleChunks.last?.isComplete, true)
    }

    func testAccumulatorYieldsProgressForReasoningWithoutAddingToFinalAnswer() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))

        let progressChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"reasoning","text":"private reasoning text","id":"prt_reasoning","messageID":"msg_assistant","sessionID":"ses_fixture"},"time":2}}
        """))

        XCTAssertEqual(progressChunks.count, 1)
        XCTAssertEqual(progressChunks[0].content, "Thinking...")
        XCTAssertEqual(progressChunks[0].metadata?["type"] as? String, "opencode_progress")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"text","text":"final answer","id":"prt_text","messageID":"msg_assistant","sessionID":"ses_fixture"},"time":3}}
        """))

        let chunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"session.idle","properties":{"sessionID":"ses_fixture"}}
        """))

        XCTAssertEqual(chunks.last?.content, "final answer")
    }

    func testAccumulatorIgnoresNonAnswerPartsInMainAssistantText() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))

        let toolChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"tool","id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_fixture","tool":"bash","state":{"status":"running","input":{"command":"ls"}}},"time":2}}
        """))
        XCTAssertEqual(toolChunks.last?.metadata?["type"] as? String, "opencode_tool")
        XCTAssertEqual(toolChunks.last?.content, "Using bash...")
        let toolOriginal = try XCTUnwrap(toolChunks.last?.metadata?["originalJSON"] as? String)
        let toolData = try XCTUnwrap(toolOriginal.data(using: .utf8))
        let toolStructured = try JSONDecoder().decode(StructuredMessageContent.self, from: toolData)
        guard case .blocks(let toolBlocks) = try XCTUnwrap(toolStructured.message?.content),
              case .toolUse(let toolUse) = try XCTUnwrap(toolBlocks.first) else {
            return XCTFail("Expected a structured tool_use block")
        }
        XCTAssertEqual(toolUse.name, "bash")
        XCTAssertEqual(toolUse.input["command"] as? String, "ls")

        let patchChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"patch","id":"prt_patch","messageID":"msg_assistant","sessionID":"ses_fixture","path":"Sources/App.swift","text":"+ let value = true"},"time":3}}
        """))
        XCTAssertEqual(patchChunks.last?.metadata?["type"] as? String, "opencode_progress")
        XCTAssertEqual(patchChunks.last?.content, "Editing files...")

        let fileChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"file","id":"prt_file","messageID":"msg_assistant","sessionID":"ses_fixture","path":"README.md"},"time":4}}
        """))
        XCTAssertEqual(fileChunks.last?.metadata?["type"] as? String, "opencode_progress")
        XCTAssertEqual(fileChunks.last?.content, "Reading README.md...")

        let textChunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"text","id":"prt_text","messageID":"msg_assistant","sessionID":"ses_fixture","text":"visible answer"},"time":5}}
        """))
        XCTAssertEqual(textChunks.last?.content, "visible answer")
    }

    func testAccumulatorMapsCompletedToolOutputToToolUseAndResultBlocks() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))

        let chunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"tool","id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_fixture","callID":"call_1","tool":"bash","state":{"status":"completed","input":{"command":"pwd"},"output":"/tmp/project"}},"time":2}}
        """))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].metadata?["type"] as? String, "opencode_tool")
        XCTAssertTrue(chunks[0].isComplete)
        XCTAssertEqual(chunks[0].content, "bash completed")

        let original = try XCTUnwrap(chunks[0].metadata?["originalJSON"] as? String)
        let originalData = try XCTUnwrap(original.data(using: .utf8))
        let structured = try JSONDecoder().decode(StructuredMessageContent.self, from: originalData)
        guard case .blocks(let blocks) = try XCTUnwrap(structured.message?.content) else {
            return XCTFail("Expected structured content blocks")
        }
        XCTAssertEqual(blocks.count, 2)

        guard case .toolUse(let toolUse) = blocks[0],
              case .toolResult(let toolResult) = blocks[1] else {
            return XCTFail("Expected tool_use followed by tool_result")
        }
        XCTAssertEqual(toolUse.id, "call_1")
        XCTAssertEqual(toolUse.name, "bash")
        XCTAssertEqual(toolUse.input["command"] as? String, "pwd")
        XCTAssertEqual(toolResult.toolUseId, "call_1")
        XCTAssertEqual(toolResult.content, "/tmp/project")
        XCTAssertFalse(toolResult.isError)
    }

    func testAccumulatorPreservesCodeAgentsUIWidgetBlocks() throws {
        var accumulator = OpenCodeChatEventAccumulator(sessionID: "ses_fixture")

        _ = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.updated","properties":{"sessionID":"ses_fixture","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_fixture","time":{"created":1}}}}
        """))

        let widgetText = """
        Here is the table widget.

        ```codeagents-ui
        { "type": "codeagents_ui", "version": 1, "elements": [
          { "type": "table", "id": "runs", "columns": ["Run", "Status"], "rows": [["1", "ok"], ["2", "fail"]] }
        ] }
        ```
        """
        let encodedWidgetText = try XCTUnwrap(String(data: try JSONEncoder().encode(widgetText), encoding: .utf8))
        let chunks = accumulator.consume(try OpenCodeEventMapper.decodeJSON("""
        {"type":"message.part.updated","properties":{"sessionID":"ses_fixture","part":{"type":"text","id":"prt_text","messageID":"msg_assistant","sessionID":"ses_fixture","text":\(encodedWidgetText)},"time":2}}
        """))

        let content = try XCTUnwrap(chunks.last?.content)
        let segments = CodeAgentsUIBlockExtractor.segments(from: content)
        XCTAssertEqual(segments.count, 2)
        guard case .ui(let block) = segments[1],
              case .table(let table) = block.elements.first else {
            return XCTFail("Expected a rendered CodeAgents UI table block")
        }
        XCTAssertEqual(table.columns, ["Run", "Status"])
        XCTAssertEqual(table.rows.count, 2)
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

    func testHydratedMessagesPreserveCodeAgentsUIWidgetBlocks() throws {
        let messages = try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data("""
        [
          {
            "info": {"role":"assistant","id":"msg_assistant","sessionID":"ses_fixture","time":{"created":1}},
            "parts": [
              {
                "type":"text",
                "text":"```codeagents-ui\\n{ \\"type\\": \\"codeagents_ui\\", \\"version\\": 1, \\"elements\\": [{ \\"type\\": \\"markdown\\", \\"id\\": \\"m1\\", \\"text\\": \\"Hydrated widget\\" }] }\\n```",
                "id":"prt_text",
                "messageID":"msg_assistant",
                "sessionID":"ses_fixture"
              }
            ]
          }
        ]
        """.utf8))

        let hydrated = OpenCodeChatMapper.hydratedMessages(from: messages)

        XCTAssertEqual(hydrated.count, 1)
        let segments = CodeAgentsUIBlockExtractor.segments(from: hydrated[0].text)
        XCTAssertEqual(segments.count, 1)
        guard case .ui(let block) = segments[0],
              case .markdown(let element) = block.elements.first else {
            return XCTFail("Expected a hydrated CodeAgents UI markdown block")
        }
        XCTAssertEqual(element.text, "Hydrated widget")
    }

    func testHydratedMessagesIgnoreNonAnswerParts() throws {
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

        XCTAssertTrue(hydrated.isEmpty)
    }
}
