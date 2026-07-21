import XCTest
@testable import CodeAgentsMobile

final class UnreadBadgeServiceTests: XCTestCase {
    func testTotalUnreadSumsAgents() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let total = UnreadBadgeMath.totalUnread(
            projectUnreads: [
                (a, 2),
                (b, 5),
                (c, 0)
            ]
        )
        XCTAssertEqual(total, 7)
    }

    func testTotalUnreadExcludesActiveAgent() {
        let a = UUID()
        let b = UUID()
        let total = UnreadBadgeMath.totalUnread(
            projectUnreads: [
                (a, 3),
                (b, 4)
            ],
            excludingProjectID: a
        )
        XCTAssertEqual(total, 4)
    }

    func testTotalUnreadIgnoresNegative() {
        let a = UUID()
        let total = UnreadBadgeMath.totalUnread(
            projectUnreads: [(a, -3), (UUID(), 2)]
        )
        XCTAssertEqual(total, 2)
    }

    func testBadgeTextFormatting() {
        XCTAssertNil(UnreadBadgeMath.badgeText(for: 0))
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 1), "1")
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 12), "12")
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 100), "99+")
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 999), "99+")
    }

    func testCannotAcknowledgeRemoteCountUntilTargetAssistantIsFinalizedLocally() {
        let sessionID = "ses_current00001"
        let streaming = Message(
            content: "Working…",
            role: .assistant,
            isComplete: false,
            isStreaming: true
        )
        streaming.originalJSON = OpenCodeChatMapper.normalizedPayloadData(
            type: "assistant",
            role: "assistant",
            text: "Working…",
            sessionID: sessionID,
            messageID: "msg_runtime_1",
            partIDs: ["part_1"],
            rawEvent: nil
        )
        let localNotice = Message(content: "Permission required to use Files.", role: .assistant)

        XCTAssertFalse(UnreadBadgeMath.isFinalizedOpenCodeAssistant(localNotice, sessionID: sessionID))
        XCTAssertFalse(UnreadBadgeMath.isFinalizedOpenCodeAssistant(streaming, sessionID: sessionID))

        streaming.isStreaming = false
        streaming.isComplete = true
        streaming.openCodeRuntimeFinalized = true
        XCTAssertTrue(
            UnreadBadgeMath.isFinalizedOpenCodeAssistant(streaming, sessionID: sessionID)
        )
        XCTAssertFalse(
            UnreadBadgeMath.isFinalizedOpenCodeAssistant(
                streaming,
                sessionID: "ses_other0000001"
            )
        )
    }

    func testCanonicalAssistantCursorDeduplicatesToolAndTextRowsByRuntimeMessageID() {
        let sessionID = "ses_current00001"
        let tool = Message(content: "Used Read", role: .assistant)
        let text = Message(content: "Done", role: .assistant)
        for message in [tool, text] {
            message.originalJSON = OpenCodeChatMapper.normalizedPayloadData(
                type: "assistant",
                role: "assistant",
                text: message.content,
                sessionID: sessionID,
                messageID: "msg_runtime_1",
                partIDs: [UUID().uuidString],
                rawEvent: nil
            )
            message.openCodeRuntimeFinalized = true
        }
        let localNotice = Message(content: "Permission required", role: .assistant)

        XCTAssertEqual(
            UnreadBadgeMath.finalizedOpenCodeAssistantCount(
                in: [tool, text, localNotice],
                sessionID: sessionID
            ),
            1
        )
    }
}
