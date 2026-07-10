import XCTest
@testable import CodeAgentsMobile

final class OpenCodeHydrationContentDigestTests: XCTestCase {
    func testMessagesNeedingHydrationWhenPartContentChanges() throws {
        let local = OpenCodeHydrationState(
            messageIDs: ["msg_1"],
            partIDs: ["prt_1"],
            partDigests: ["prt_1": "olddigest"]
        )
        let remoteJSON = """
        [{"info":{"id":"msg_1","role":"assistant","time":{"created":1}},"parts":[{"type":"text","id":"prt_1","text":"final answer"}]}]
        """
        let remote = try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data(remoteJSON.utf8))
        let selected = OpenCodeHydrationDiffer.messagesNeedingHydration(local: local, remoteMessages: remote)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.info.id, "msg_1")
    }

    func testMessagesSkippedWhenDigestsMatch() throws {
        let remoteJSON = """
        [{"info":{"id":"msg_1","role":"assistant","time":{"created":1}},"parts":[{"type":"text","id":"prt_1","text":"same"}]}]
        """
        let remote = try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data(remoteJSON.utf8))
        let observed = OpenCodeHydrationState(messages: remote)
        let selected = OpenCodeHydrationDiffer.messagesNeedingHydration(local: observed, remoteMessages: remote)
        XCTAssertTrue(selected.isEmpty)
    }
}
