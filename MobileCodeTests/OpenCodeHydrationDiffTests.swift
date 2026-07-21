import XCTest
@testable import CodeAgentsMobile

final class OpenCodeHydrationDiffTests: XCTestCase {
    func testInitialHydrationModeUsesNamedBoundedLimit() {
        let mode = OpenCodeHydrationMode.initialBounded()

        XCTAssertEqual(mode.limit, OpenCodeHydrationPolicy.initialMessageLimit)
        XCTAssertFalse(mode.replacesStoredState)
        XCTAssertGreaterThan(OpenCodeHydrationPolicy.initialMessageLimit, 0)
    }

    func testFullRefreshHydrationModeOmitsLimitAndReplacesState() {
        let mode = OpenCodeHydrationMode.fullRefresh

        XCTAssertNil(mode.limit)
        XCTAssertTrue(mode.replacesStoredState)
    }

    func testDiffSelectionIncludesNewMessages() throws {
        let remote = try messages([
            ("msg_existing", ["prt_existing"]),
            ("msg_new", ["prt_new"])
        ])
        // Local digests match the existing remote part so only the new message is selected.
        let local = OpenCodeHydrationState(messages: Array(remote.prefix(1)))

        let selected = OpenCodeHydrationDiffer.messagesNeedingHydration(local: local, remoteMessages: remote)

        XCTAssertEqual(selected.map(\.info.id), ["msg_new"])
    }

    func testDiffSelectionIncludesSameMessageWithNewPart() throws {
        let remote = try messages([
            ("msg_existing", ["prt_existing", "prt_new"])
        ])
        let existingOnly = try messages([
            ("msg_existing", ["prt_existing"])
        ])
        let local = OpenCodeHydrationState(messages: existingOnly)

        let selected = OpenCodeHydrationDiffer.messagesNeedingHydration(local: local, remoteMessages: remote)

        XCTAssertEqual(selected.map(\.info.id), ["msg_existing"])
    }

    func testDiffSelectionSkipsUnchangedSnapshot() throws {
        let remote = try messages([
            ("msg_existing", ["prt_existing"])
        ])
        let local = OpenCodeHydrationState(messages: remote)

        let selected = OpenCodeHydrationDiffer.messagesNeedingHydration(local: local, remoteMessages: remote)

        XCTAssertTrue(selected.isEmpty)
    }

    func testDiffSelectionIncludesCompletionOnlyTransition() throws {
        let unfinished = try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data("""
        [{"info":{"id":"msg_existing","role":"assistant","sessionID":"ses_fixture","time":{"created":1}},"parts":[{"type":"text","id":"prt_existing","messageID":"msg_existing","sessionID":"ses_fixture","text":"same text"}]}]
        """.utf8))
        let completed = try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data("""
        [{"info":{"id":"msg_existing","role":"assistant","sessionID":"ses_fixture","time":{"created":1,"completed":2}},"parts":[{"type":"text","id":"prt_existing","messageID":"msg_existing","sessionID":"ses_fixture","text":"same text"}]}]
        """.utf8))
        let local = OpenCodeHydrationState(messages: unfinished)

        let selected = OpenCodeHydrationDiffer.messagesNeedingHydration(
            local: local,
            remoteMessages: completed
        )
        let diff = OpenCodeHydrationDiffer.diff(local: local, remoteMessages: completed)

        XCTAssertEqual(selected.map(\.info.id), ["msg_existing"])
        XCTAssertEqual(diff.updatedPartIDs, ["prt_existing"])
        XCTAssertTrue(diff.hasChanges)
    }

    func testBoundedStateMergingKeepsOutOfWindowIDs() throws {
        let remote = try messages([
            ("msg_recent", ["prt_recent"])
        ])
        let local = OpenCodeHydrationState(messageIDs: ["msg_old"], partIDs: ["prt_old"])

        let merged = OpenCodeHydrationDiffer.mergedState(
            local: local,
            observedMessages: remote,
            mode: .initialBounded(limit: 1)
        )

        XCTAssertEqual(merged.messageIDs, ["msg_old", "msg_recent"])
        XCTAssertEqual(merged.partIDs, ["prt_old", "prt_recent"])
    }

    func testFullRefreshStateReplacesOutOfWindowIDs() throws {
        let remote = try messages([
            ("msg_current", ["prt_current"])
        ])
        let local = OpenCodeHydrationState(messageIDs: ["msg_old"], partIDs: ["prt_old"])

        let merged = OpenCodeHydrationDiffer.mergedState(
            local: local,
            observedMessages: remote,
            mode: .fullRefresh
        )

        XCTAssertEqual(merged.messageIDs, ["msg_current"])
        XCTAssertEqual(merged.partIDs, ["prt_current"])
    }

    func testExistingHydratedRuntimeMessageUpdatesInsteadOfInsertingDuplicate() {
        let hydrated = hydratedMessage(id: "msg_existing", role: .assistant, text: "updated")

        let action = OpenCodeHydratedMessageMerge.action(
            for: hydrated,
            existingRuntimeMessageIDs: ["msg_existing"],
            hasLocalUserMessage: false
        )

        XCTAssertEqual(action, .updateExisting)
    }

    func testHydratedLocalUserPromptEchoSkipsInsertionWhenRuntimeMessageIsNew() {
        let hydrated = hydratedMessage(id: "msg_remote_echo", role: .user, text: "same prompt")

        let action = OpenCodeHydratedMessageMerge.action(
            for: hydrated,
            existingRuntimeMessageIDs: [],
            hasLocalUserMessage: true
        )

        XCTAssertEqual(action, .skipLocalUserDuplicate)
    }

    func testNewHydratedAssistantMessageInsertsWhenNoDuplicateExists() {
        let hydrated = hydratedMessage(id: "msg_new", role: .assistant, text: "new reply")

        let action = OpenCodeHydratedMessageMerge.action(
            for: hydrated,
            existingRuntimeMessageIDs: [],
            hasLocalUserMessage: false
        )

        XCTAssertEqual(action, .insert)
    }

    private func messages(_ definitions: [(messageID: String, partIDs: [String])]) throws -> [OpenCodeSessionMessage] {
        let json = definitions.map { definition in
            let parts = definition.partIDs.map { partID in
                """
                {"type":"text","id":"\(partID)","messageID":"\(definition.messageID)","sessionID":"ses_fixture","text":"\(partID)"}
                """
            }.joined(separator: ",")

            return """
            {"info":{"id":"\(definition.messageID)","role":"assistant","sessionID":"ses_fixture","time":{"created":1}},"parts":[\(parts)]}
            """
        }.joined(separator: ",")

        return try JSONDecoder().decode([OpenCodeSessionMessage].self, from: Data("[\(json)]".utf8))
    }

    private func hydratedMessage(id: String, role: MessageRole, text: String) -> CodingAgentRuntimeHydratedMessage {
        CodingAgentRuntimeHydratedMessage(
            runtimeMessageID: id,
            runtimePartIDs: ["prt_\(id)"],
            role: role,
            text: text,
            createdAt: nil,
            originalPayload: nil
        )
    }
}
