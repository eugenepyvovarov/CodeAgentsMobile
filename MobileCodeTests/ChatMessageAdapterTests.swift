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
        XCTAssertEqual(adapter.exyteMessages.count, 1)
        XCTAssertEqual(adapter.exyteMessages[0].text, "Session Info")
    }

    func testToolUseOnlyMessageGetsNonEmptyExyteText() throws {
        let jsonLine = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Glob","input":{"pattern":"**/*.md"}}]}}
        """
        let message = Message(content: "", role: .assistant)
        message.originalJSON = jsonLine.data(using: .utf8)

        let adapter = ChatMessageAdapter(messages: [message], streamingMessageId: nil)
        XCTAssertEqual(adapter.exyteMessages.count, 1)
        XCTAssertTrue(adapter.exyteMessages[0].text.contains("Tool:"))
        XCTAssertTrue(adapter.exyteMessages[0].text.contains("Glob"))
    }

    func testStreamingPlaceholderMessageUsesEllipsisText() throws {
        let message = Message(content: "", role: .assistant, isComplete: false, isStreaming: true)

        let adapter = ChatMessageAdapter(messages: [message], streamingMessageId: message.id)
        XCTAssertEqual(adapter.exyteMessages.count, 1)
        XCTAssertEqual(adapter.exyteMessages[0].text, "...")
    }
}

