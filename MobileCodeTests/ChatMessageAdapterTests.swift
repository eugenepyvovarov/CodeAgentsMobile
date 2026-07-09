import XCTest
@testable import CodeAgentsMobile

final class ChatMessageAdapterTests: XCTestCase {
    func testSystemInitMessageGetsSessionInfoExyteText() throws {
        let jsonLine = """
        {"type":"system","subtype":"init","cwd":"/root/projects/WWW","session_id":"bccdf276-6dcc-4a89-b43a-376be8fcb3ba","tools":["Bash"]}
        """
        let message = Message(content: "", role: .assistant)
        message.originalJSON = jsonLine.data(using: .utf8)

        let adapter = ChatMessageAdapter(messages: [message], streamingMessageId: nil)
        XCTAssertEqual(adapter.exyteMessages.count, 0)
    }

    func testToolUseOnlyMessageGetsNonEmptyExyteText() throws {
        let jsonLine = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Glob","input":{"pattern":"**/*.md"}}]}}
        """
        let message = Message(content: "", role: .assistant)
        message.originalJSON = jsonLine.data(using: .utf8)

        let adapter = ChatMessageAdapter(messages: [message], streamingMessageId: nil)
        XCTAssertEqual(adapter.exyteMessages.count, 1)
        let firstMessage = try XCTUnwrap(adapter.exyteMessages.first, "Expected one adapter message")
        // Quiet activity chip text (friendly title + detail), not raw "Tool: Glob".
        XCTAssertTrue(firstMessage.text.contains("Found files"), firstMessage.text)
        XCTAssertTrue(firstMessage.text.contains("**/*.md") || firstMessage.text.contains("*.md"), firstMessage.text)
    }

    func testStreamingPlaceholderMessageUsesEllipsisText() throws {
        let message = Message(content: "", role: .assistant, isComplete: false, isStreaming: true)

        let adapter = ChatMessageAdapter(messages: [message], streamingMessageId: message.id)
        XCTAssertEqual(adapter.exyteMessages.count, 1)
        let firstMessage = try XCTUnwrap(adapter.exyteMessages.first, "Expected one adapter message")
        XCTAssertEqual(firstMessage.text, "...")
    }
}
