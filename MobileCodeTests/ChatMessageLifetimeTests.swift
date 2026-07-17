import SwiftData
import XCTest
@testable import CodeAgentsMobile

@MainActor
final class ChatMessageLifetimeTests: XCTestCase {
    func testClearChatRemovesObservableModelsBeforePersistedDeletionCompletes() throws {
        let (container, context) = try makeContainer()
        let projectID = UUID()
        let message = Message(content: "Hello", role: .assistant, projectId: projectID)
        context.insert(message)
        try context.save()

        let viewModel = ChatViewModel()
        viewModel.modelContext = context
        viewModel.projectId = projectID
        viewModel.messages = [message]
        viewModel.streamingMessage = message

        viewModel.clearChat()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.streamingMessage)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), 0)
        withExtendedLifetime(container) {}
    }

    func testTransientRemovalClearsStreamingReferenceAndPersistence() throws {
        let (container, context) = try makeContainer()
        let message = Message(content: "", role: .assistant, isComplete: false, isStreaming: true)
        context.insert(message)
        try context.save()

        let viewModel = ChatViewModel()
        viewModel.modelContext = context
        viewModel.messages = [message]
        viewModel.streamingMessage = message

        viewModel.removeTransientOpenCodeMessage(message)

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.streamingMessage)
        XCTAssertTrue(viewModel.streamingBlocks.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Message>()), 0)
        withExtendedLifetime(container) {}
    }

    func testDetachedRenderMessageRemainsReadableAfterSourceDeletion() throws {
        let (container, context) = try makeContainer()
        let message = Message(content: "Persisted", role: .assistant)
        message.isLocalError = true
        context.insert(message)
        try context.save()

        let renderMessage = message.detachedForRendering()
        context.delete(message)
        try context.save()

        XCTAssertEqual(renderMessage.content, "Persisted")
        guard case .assistant = renderMessage.role else {
            return XCTFail("Expected the detached render message to preserve its role")
        }
        XCTAssertTrue(renderMessage.isLocalError)
        XCTAssertNil(renderMessage.modelContext)
        withExtendedLifetime(container) {}
    }

    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([Message.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }
}
