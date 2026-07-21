import XCTest
import SwiftData
@testable import CodeAgentsMobile

final class AgentChatPreviewTests: XCTestCase {
    func testNormalizeCollapsesWhitespace() {
        let result = AgentChatPreviewText.normalize("Hello\n\n  world\tthere")
        XCTAssertEqual(result.body, "Hello world there")
        XCTAssertEqual(result.activity, .none)
    }

    func testNormalizeStripsCodeAgentsUIBlocks() {
        let raw = """
        Done.
        ```codeagents-ui
        { "type": "codeagents_ui", "elements": [] }
        ```
        More text.
        """
        let result = AgentChatPreviewText.normalize(raw)
        XCTAssertEqual(result.body, "Done. More text.")
        XCTAssertFalse(result.body.contains("codeagents"))
        XCTAssertEqual(result.activity, .none)
    }

    func testNormalizeTruncatesLongText() {
        let long = String(repeating: "a", count: 200)
        let result = AgentChatPreviewText.normalize(long, maxLength: 40)
        XCTAssertTrue(result.body.hasSuffix("…"))
        XCTAssertLessThanOrEqual(result.body.count, 41)
        XCTAssertEqual(result.activity, .none)
    }

    func testNormalizeMapsUsingToolToFriendlyLabel() {
        let result = AgentChatPreviewText.normalize(
            "Using codeagents-scheduled-tasks_list_scheduled_tasks..."
        )
        XCTAssertEqual(result.body, "Using tools…")
        XCTAssertEqual(result.activity, .tools)
        XCTAssertEqual(result.activity.systemImage, "wrench.and.screwdriver.fill")
    }

    func testNormalizeMapsBareToolId() {
        let result = AgentChatPreviewText.normalize("codeagents-scheduled-tasks_list_scheduled_tasks")
        XCTAssertEqual(result.body, "Using tools…")
        XCTAssertEqual(result.activity, .tools)
    }

    func testNormalizeMapsThinking() {
        let result = AgentChatPreviewText.normalize("Thinking...")
        XCTAssertEqual(result.body, "Thinking…")
        XCTAssertEqual(result.activity, .thinking)
    }

    func testNormalizeMapsReading() {
        let result = AgentChatPreviewText.normalize("Reading Package.swift...")
        XCTAssertEqual(result.body, "Reading files…")
        XCTAssertEqual(result.activity, .reading)
    }

    func testListLinePrefixesYou() {
        let preview = AgentChatPreview(
            sender: .you,
            body: "ship it",
            timestamp: Date(),
            isStreaming: false,
            activity: .none
        )
        XCTAssertEqual(preview.listLine, "You: ship it")
    }

    func testListLineAgentIsBareBody() {
        let preview = AgentChatPreview(
            sender: .agent,
            body: "All green",
            timestamp: Date(),
            isStreaming: false,
            activity: .none
        )
        XCTAssertEqual(preview.listLine, "All green")
    }

    func testListLineTypingPlaceholder() {
        let preview = AgentChatPreview(
            sender: .agent,
            body: "",
            timestamp: Date(),
            isStreaming: true,
            activity: .typing
        )
        XCTAssertEqual(preview.listLine, "Typing…")
    }

    func testListLineToolActivity() {
        let preview = AgentChatPreview(
            sender: .agent,
            body: "Using tools…",
            timestamp: Date(),
            isStreaming: true,
            activity: .tools
        )
        XCTAssertEqual(preview.listLine, "Using tools…")
        XCTAssertNotNil(preview.activity.systemImage)
    }

    func testPreviewSelectorReflectsInPlaceStreamingCompletion() throws {
        let message = Message(
            content: "",
            role: .assistant,
            projectId: UUID(),
            isComplete: false,
            isStreaming: true
        )

        let streaming = try XCTUnwrap(
            AgentChatPreviewLoader.preview(fromNewestFirst: [message])
        )
        XCTAssertEqual(streaming.listLine, "Typing…")
        XCTAssertTrue(streaming.isStreaming)

        message.content = "Final answer"
        message.isStreaming = false
        message.isComplete = true

        let completed = try XCTUnwrap(
            AgentChatPreviewLoader.preview(fromNewestFirst: [message])
        )
        XCTAssertEqual(completed.listLine, "Final answer")
        XCTAssertFalse(completed.isStreaming)
    }

    @MainActor
    func testPersistedLoaderReflectsInPlaceStreamingCompletion() throws {
        let schema = Schema([Message.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let projectId = UUID()
        let message = Message(
            content: "",
            role: .assistant,
            projectId: projectId,
            isComplete: false,
            isStreaming: true
        )
        context.insert(message)
        try context.save()

        XCTAssertEqual(
            AgentChatPreviewLoader.load(projectId: projectId, in: context)?.listLine,
            "Typing…"
        )

        message.content = "Persisted final answer"
        message.isStreaming = false
        message.isComplete = true
        try context.save()

        let completed = try XCTUnwrap(
            AgentChatPreviewLoader.load(projectId: projectId, in: context)
        )
        XCTAssertEqual(completed.listLine, "Persisted final answer")
        XCTAssertFalse(completed.isStreaming)
        withExtendedLifetime(container) {}
    }

    func testTimestampTodayIsTimeOnly() {
        let now = Date()
        let formatted = AgentChatListTimestamp.format(now, now: now)
        XCTAssertFalse(formatted.localizedCaseInsensitiveContains("yesterday"))
        XCTAssertFalse(formatted.isEmpty)
    }

    func testTimestampYesterday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let formatted = AgentChatListTimestamp.format(yesterday, now: now)
        XCTAssertEqual(formatted, "Yesterday")
    }

    func testMonogramUsesInitials() {
        XCTAssertEqual(AgentAvatarView.monogram(from: "Ops Bot"), "OB")
        XCTAssertEqual(AgentAvatarView.monogram(from: "mobile-code"), "MC")
        XCTAssertEqual(AgentAvatarView.monogram(from: "solo"), "S")
    }
}
