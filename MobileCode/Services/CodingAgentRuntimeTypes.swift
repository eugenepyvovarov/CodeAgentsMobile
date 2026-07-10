//
//  CodingAgentRuntimeTypes.swift
//  CodeAgentsMobile
//
//  Purpose: Runtime-neutral types, selection store, and service protocol.
//           Production chat uses OpenCode only; `.claudeProxy` remains for decode/migration.
//

import Foundation

enum CodingAgentRuntimeKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case claudeProxy = "claudeProxy"
    case openCode = "openCode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeProxy:
            return "Claude Proxy (Legacy)"
        case .openCode:
            return "OpenCode"
        }
    }
}

struct CodingAgentRuntimeSelectionStore {
    static let selectedRuntimeKey = "CodingAgentRuntime.SelectedRuntime"
    static let defaultRuntime = CodingAgentRuntimeKind.openCode

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func selectedRuntime() -> CodingAgentRuntimeKind {
        guard let rawValue = userDefaults.string(forKey: Self.selectedRuntimeKey),
              let runtime = CodingAgentRuntimeKind(rawValue: rawValue) else {
            return Self.defaultRuntime
        }
        return runtime
    }

    func setSelectedRuntime(_ runtime: CodingAgentRuntimeKind) {
        userDefaults.set(runtime.rawValue, forKey: Self.selectedRuntimeKey)
    }
}

enum CodingAgentRuntimeResolver {
    static func runtimeKind(
        for project: RemoteProject,
        selectionStore: CodingAgentRuntimeSelectionStore = CodingAgentRuntimeSelectionStore()
    ) -> CodingAgentRuntimeKind {
        // Keep the parameter for call-site compatibility; missing/unknown markers resolve to OpenCode.
        _ = selectionStore
        guard let rawValue = project.agentRuntimeRawValue,
              let runtime = CodingAgentRuntimeKind(rawValue: rawValue) else {
            return .openCode
        }
        return runtime
    }
}

struct CodingAgentRuntimeHealth: Equatable {
    enum Status: Equatable {
        case available
        case unavailable
        case unknown
    }

    let status: Status
    let runtime: CodingAgentRuntimeKind
    let version: String?
    let message: String?

    static func available(runtime: CodingAgentRuntimeKind, version: String? = nil) -> Self {
        CodingAgentRuntimeHealth(status: .available, runtime: runtime, version: version, message: nil)
    }

    static func unavailable(runtime: CodingAgentRuntimeKind, message: String) -> Self {
        CodingAgentRuntimeHealth(status: .unavailable, runtime: runtime, version: nil, message: message)
    }

    static func unknown(runtime: CodingAgentRuntimeKind, message: String? = nil) -> Self {
        CodingAgentRuntimeHealth(status: .unknown, runtime: runtime, version: nil, message: message)
    }
}

struct CodingAgentRuntimeSessionState: Equatable {
    enum Status: Equatable {
        case idle
        case busy
        case retrying
        case unknown(String?)
    }

    let runtime: CodingAgentRuntimeKind
    let status: Status

    static func idle(runtime: CodingAgentRuntimeKind) -> Self {
        CodingAgentRuntimeSessionState(runtime: runtime, status: .idle)
    }

    static func openCode(runtime: CodingAgentRuntimeKind, rawStatus: String?) -> Self {
        switch rawStatus?.lowercased() {
        case nil:
            return CodingAgentRuntimeSessionState(runtime: runtime, status: .idle)
        case "idle":
            return CodingAgentRuntimeSessionState(runtime: runtime, status: .idle)
        case "busy":
            return CodingAgentRuntimeSessionState(runtime: runtime, status: .busy)
        case "retry", "retrying":
            return CodingAgentRuntimeSessionState(runtime: runtime, status: .retrying)
        case let value:
            return CodingAgentRuntimeSessionState(runtime: runtime, status: .unknown(value))
        }
    }
}

struct CodingAgentRuntimeHydratedMessage: Equatable {
    let runtimeMessageID: String
    let runtimePartIDs: [String]
    let role: MessageRole
    let text: String
    let createdAt: Date?
    let originalPayload: Data?
}

enum CodingAgentRuntimeError: LocalizedError {
    case unsupported(String)
    case missingSession

    var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        case .missingSession:
            return "No runtime session is available."
        }
    }
}

@MainActor
protocol CodingAgentRuntimeService: AnyObject {
    var kind: CodingAgentRuntimeKind { get }
    var displayName: String { get }

    func health(for project: RemoteProject) async -> CodingAgentRuntimeHealth
    func sessionState(for project: RemoteProject) async throws -> CodingAgentRuntimeSessionState
    func sendMessage(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID?,
        mcpServers: [MCPServer]
    ) -> AsyncThrowingStream<MessageChunk, Error>
    /// Submit a prompt without attaching a new event stream (soft-steer while a stream is already live).
    func submitPrompt(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID?,
        mcpServers: [MCPServer]
    ) async throws
    func hydrateMessages(for project: RemoteProject) async throws -> [CodingAgentRuntimeHydratedMessage]
    func hydrateMessages(for project: RemoteProject, mode: OpenCodeHydrationMode) async throws -> OpenCodeHydrationResult
    func abort(project: RemoteProject) async throws
    func replyToPermission(
        project: RemoteProject,
        permissionId: String,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope,
        message: String?
    ) async throws
    func replyToQuestion(project: RemoteProject, questionId: String, answers: [[String]]) async throws
    func rejectQuestion(project: RemoteProject, questionId: String) async throws
    func reset(project: RemoteProject) async throws
}

extension CodingAgentRuntimeService {
    var displayName: String { kind.displayName }

    func sessionState(for project: RemoteProject) async throws -> CodingAgentRuntimeSessionState {
        .idle(runtime: kind)
    }

    func hydrateMessages(for project: RemoteProject, mode: OpenCodeHydrationMode) async throws -> OpenCodeHydrationResult {
        let hydratedMessages = try await hydrateMessages(for: project)
        let state = project.openCodeHydrationState
        return OpenCodeHydrationResult(
            mode: mode,
            fetchedCount: hydratedMessages.count,
            selectedCount: hydratedMessages.count,
            hydratedMessages: hydratedMessages,
            previousState: state,
            observedState: state,
            storedState: state,
            diff: OpenCodeHydrationDiffer.diff(local: state, remote: state)
        )
    }

    func submitPrompt(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID?,
        mcpServers: [MCPServer]
    ) async throws {
        throw CodingAgentRuntimeError.unsupported("This runtime does not support mid-answer prompt submission.")
    }

    func replyToQuestion(project: RemoteProject, questionId: String, answers: [[String]]) async throws {
        throw CodingAgentRuntimeError.unsupported("This runtime does not support interactive questions.")
    }

    func rejectQuestion(project: RemoteProject, questionId: String) async throws {
        throw CodingAgentRuntimeError.unsupported("This runtime does not support interactive questions.")
    }
}
