import XCTest
@testable import CodeAgentsMobile

final class CodingAgentRuntimeSelectionTests: XCTestCase {
    func testRuntimeSelectionDefaultsToClaudeProxy() throws {
        let defaults = try makeDefaults()
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedRuntime(), .claudeProxy)
    }

    func testRuntimeSelectionPersistsOpenCode() throws {
        let defaults = try makeDefaults()
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)

        store.setSelectedRuntime(.openCode)

        XCTAssertEqual(store.selectedRuntime(), .openCode)
        XCTAssertEqual(defaults.string(forKey: CodingAgentRuntimeSelectionStore.selectedRuntimeKey), "openCode")
    }

    func testRuntimeSelectionFallsBackWhenStoredValueIsUnknown() throws {
        let defaults = try makeDefaults()
        defaults.set("futureRuntime", forKey: CodingAgentRuntimeSelectionStore.selectedRuntimeKey)
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedRuntime(), .claudeProxy)
    }

    func testRuntimeResolverUsesProjectRuntimeBeforeGlobalDefault() throws {
        let defaults = try makeDefaults()
        let store = CodingAgentRuntimeSelectionStore(userDefaults: defaults)
        store.setSelectedRuntime(.openCode)
        let project = RemoteProject(name: "Test", serverId: UUID())

        XCTAssertEqual(CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: store), .openCode)

        project.selectedAgentRuntime = .claudeProxy
        XCTAssertEqual(CodingAgentRuntimeResolver.runtimeKind(for: project, selectionStore: store), .claudeProxy)
    }

    func testRuntimeDisplayNames() {
        XCTAssertEqual(CodingAgentRuntimeKind.claudeProxy.displayName, "Claude Proxy")
        XCTAssertEqual(CodingAgentRuntimeKind.openCode.displayName, "OpenCode")
        XCTAssertEqual(ConnectionPurpose.opencode.description, "OpenCode")
    }

    @MainActor
    func testRuntimeRegistryReturnsRuntimeForKind() {
        let claude = StubRuntime(kind: .claudeProxy)
        let openCode = StubRuntime(kind: .openCode)
        let registry = CodingAgentRuntimeRegistry(claudeRuntime: claude, openCodeRuntime: openCode)

        XCTAssertTrue(registry.runtime(for: .claudeProxy) === claude)
        XCTAssertTrue(registry.runtime(for: .openCode) === openCode)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CodingAgentRuntimeSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class StubRuntime: CodingAgentRuntimeService {
    let kind: CodingAgentRuntimeKind

    init(kind: CodingAgentRuntimeKind) {
        self.kind = kind
    }

    func health(for project: RemoteProject) async -> CodingAgentRuntimeHealth {
        .unknown(runtime: kind)
    }

    func sendMessage(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID?,
        mcpServers: [MCPServer]
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func hydrateMessages(for project: RemoteProject) async throws -> [CodingAgentRuntimeHydratedMessage] {
        []
    }

    func abort(project: RemoteProject) async throws {}

    func replyToPermission(
        project: RemoteProject,
        permissionId: String,
        decision: ToolApprovalDecision,
        message: String?
    ) async throws {}

    func reset(project: RemoteProject) async throws {}
}
