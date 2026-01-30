import XCTest
@testable import CodeAgentsMobile

final class StreamingJSONParserTests: XCTestCase {
    func testToolUseNormalizedLineDecodes() throws {
        let line = "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls -la\"}}"
        let chunk = StreamingJSONParser.parseStreamingLine(line)
        let normalized = chunk?.metadata?["normalizedJSON"] as? String
        XCTAssertNotNil(normalized)

        let data = try XCTUnwrap(normalized?.data(using: .utf8))
        let structured = try JSONDecoder().decode(StructuredMessageContent.self, from: data)
        XCTAssertEqual(structured.type, "assistant")

        guard let message = structured.message else {
            return XCTFail("Expected message content")
        }

        switch message.content {
        case .blocks(let blocks):
            let hasToolUse = blocks.contains { block in
                if case .toolUse(let toolUse) = block {
                    return toolUse.id == "toolu_1" && toolUse.name == "Bash"
                }
                return false
            }
            XCTAssertTrue(hasToolUse)
        case .text:
            XCTFail("Expected blocks content")
        }
    }

    func testToolResultNormalizedLineDecodes() throws {
        let line = "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"ok\",\"is_error\":false}"
        let chunk = StreamingJSONParser.parseStreamingLine(line)
        let normalized = chunk?.metadata?["normalizedJSON"] as? String
        XCTAssertNotNil(normalized)

        let data = try XCTUnwrap(normalized?.data(using: .utf8))
        let structured = try JSONDecoder().decode(StructuredMessageContent.self, from: data)
        XCTAssertEqual(structured.type, "user")

        guard let message = structured.message else {
            return XCTFail("Expected message content")
        }

        switch message.content {
        case .blocks(let blocks):
            let hasToolResult = blocks.contains { block in
                if case .toolResult(let toolResult) = block {
                    return toolResult.toolUseId == "toolu_1"
                }
                return false
            }
            XCTAssertTrue(hasToolResult)
        case .text:
            XCTFail("Expected blocks content")
        }
    }

    func testFixtureProducesToolBlocks() throws {
        let fixture = try loadFixture(named: "claude_stream_tool_calls.ndjson")
        let lines = fixture.split(separator: "\n").map { String($0) }

        var storedLines: [String] = []
        for line in lines {
            if let chunk = StreamingJSONParser.parseStreamingLine(line) {
                let normalized = chunk.metadata?["normalizedJSON"] as? String
                let original = chunk.metadata?["originalJSON"] as? String
                if let jsonLine = normalized ?? original {
                    storedLines.append(jsonLine)
                }
            }
        }

        let jsonData = storedLines.joined(separator: "\n").data(using: .utf8)
        let message = Message(content: "", role: .assistant)
        message.originalJSON = jsonData

        let structuredMessages = message.structuredMessages ?? []
        let blocks = structuredMessages.compactMap { structured -> [ContentBlock]? in
            guard let content = structured.message else { return nil }
            switch content.content {
            case .blocks(let blocks):
                return blocks
            case .text:
                return nil
            }
        }.flatMap { $0 }

        let toolUseCount = blocks.filter { block in
            if case .toolUse = block { return true }
            return false
        }.count

        let toolResultCount = blocks.filter { block in
            if case .toolResult = block { return true }
            return false
        }.count

        XCTAssertEqual(toolUseCount, 1)
        XCTAssertEqual(toolResultCount, 1)
    }

    func testAssistantToolUseIncludesInput() throws {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la","flags":["-a","-l"]}}]}}
        """
        let chunk = StreamingJSONParser.parseStreamingLine(line)
        let metadata = try XCTUnwrap(chunk?.metadata)
        let contentBlocks = try XCTUnwrap(metadata["content"] as? [[String: Any]])
        let toolBlock = try XCTUnwrap(contentBlocks.first { ($0["type"] as? String) == "tool_use" })
        let input = try XCTUnwrap(toolBlock["input"] as? [String: Any])
        XCTAssertEqual(input["command"] as? String, "ls -la")
        let flags = input["flags"] as? [Any]
        let flagStrings = flags?.compactMap { $0 as? String } ?? []
        XCTAssertEqual(flagStrings, ["-a", "-l"])
    }

    func testFallbackContentBlocksParsesTopLevelToolUseLine() throws {
        let line = "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls -la\"}}"
        let message = Message(content: "", role: .assistant)
        message.originalJSON = line.data(using: .utf8)

        let blocks = message.fallbackContentBlocks()
        let hasToolUse = blocks.contains { block in
            if case .toolUse(let toolUse) = block {
                return toolUse.id == "toolu_1" && toolUse.name == "Bash"
            }
            return false
        }
        XCTAssertTrue(hasToolUse)
    }

    func testFallbackContentBlocksParsesTopLevelToolResultLine() throws {
        let line = "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"ok\",\"is_error\":false}"
        let message = Message(content: "", role: .assistant)
        message.originalJSON = line.data(using: .utf8)

        let blocks = message.fallbackContentBlocks()
        let hasToolResult = blocks.contains { block in
            if case .toolResult(let toolResult) = block {
                return toolResult.toolUseId == "toolu_1" && toolResult.content == "ok"
            }
            return false
        }
        XCTAssertTrue(hasToolResult)
    }

    private func loadFixture(named name: String) throws -> String {
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try String(contentsOf: fixturesURL, encoding: .utf8)
    }
}

