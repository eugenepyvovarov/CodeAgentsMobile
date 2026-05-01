//
//  CodingAgentRuntimeService.swift
//  CodeAgentsMobile
//
//  Purpose: Runtime-neutral boundary for Claude proxy and OpenCode integrations
//

import Foundation

enum CodingAgentRuntimeKind: String, CaseIterable, Codable, Identifiable {
    case claudeProxy = "claudeProxy"
    case openCode = "openCode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeProxy:
            return "Claude Proxy"
        case .openCode:
            return "OpenCode"
        }
    }
}

struct CodingAgentRuntimeSelectionStore {
    static let selectedRuntimeKey = "CodingAgentRuntime.SelectedRuntime"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func selectedRuntime() -> CodingAgentRuntimeKind {
        guard let rawValue = userDefaults.string(forKey: Self.selectedRuntimeKey),
              let runtime = CodingAgentRuntimeKind(rawValue: rawValue) else {
            return .claudeProxy
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
        if project.agentRuntimeRawValue != nil {
            return project.selectedAgentRuntime
        }
        return selectionStore.selectedRuntime()
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
    func hydrateMessages(for project: RemoteProject) async throws -> [CodingAgentRuntimeHydratedMessage]
    func abort(project: RemoteProject) async throws
    func replyToPermission(
        project: RemoteProject,
        permissionId: String,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope,
        message: String?
    ) async throws
    func reset(project: RemoteProject) async throws
}

extension CodingAgentRuntimeService {
    var displayName: String { kind.displayName }

    func sessionState(for project: RemoteProject) async throws -> CodingAgentRuntimeSessionState {
        .idle(runtime: kind)
    }
}

@MainActor
final class ClaudeProxyRuntimeService: CodingAgentRuntimeService {
    let kind = CodingAgentRuntimeKind.claudeProxy

    private let claudeService: ClaudeCodeService

    init(claudeService: ClaudeCodeService? = nil) {
        self.claudeService = claudeService ?? .shared
    }

    func health(for project: RemoteProject) async -> CodingAgentRuntimeHealth {
        guard let server = ServerManager.shared.server(withId: project.serverId) else {
            return .unavailable(runtime: kind, message: "Project server is not available.")
        }

        let installed = await claudeService.checkClaudeInstallation(for: server)
        return installed
            ? .available(runtime: kind)
            : .unavailable(runtime: kind, message: "Claude Code is not installed.")
    }

    func sendMessage(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID? = nil,
        mcpServers: [MCPServer] = []
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        claudeService.sendMessage(text, in: project, messageId: messageId, mcpServers: mcpServers)
    }

    func hydrateMessages(for project: RemoteProject) async throws -> [CodingAgentRuntimeHydratedMessage] {
        throw CodingAgentRuntimeError.unsupported("Claude proxy hydration still uses proxy event replay.")
    }

    func abort(project: RemoteProject) async throws {
        throw CodingAgentRuntimeError.unsupported("Claude proxy abort is still handled by the existing chat flow.")
    }

    func replyToPermission(
        project: RemoteProject,
        permissionId: String,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope = .once,
        message: String?
    ) async throws {
        try await claudeService.sendProxyToolPermission(
            project: project,
            permissionId: permissionId,
            decision: decision,
            message: message
        )
    }

    func reset(project: RemoteProject) async throws {
        project.claudeSessionId = nil
        project.proxyConversationId = nil
        project.proxyConversationGroupId = nil
        project.proxyLastEventId = nil
        project.updateLastModified()
    }
}

@MainActor
final class OpenCodeRuntimeService: CodingAgentRuntimeService {
    let kind = CodingAgentRuntimeKind.openCode

    private let sshService: SSHService
    private let client: OpenCodeClient

    init(sshService: SSHService? = nil, client: OpenCodeClient = OpenCodeClient()) {
        self.sshService = sshService ?? .shared
        self.client = client
    }

    func health(for project: RemoteProject) async -> CodingAgentRuntimeHealth {
        do {
            let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
            let health = try await client.health(session: sshSession)
            return health.healthy
                ? .available(runtime: kind, version: health.version)
                : .unavailable(runtime: kind, message: "OpenCode server reported unhealthy.")
        } catch {
            return .unavailable(runtime: kind, message: error.localizedDescription)
        }
    }

    func sendMessage(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID? = nil,
        mcpServers: [MCPServer] = []
    ) -> AsyncThrowingStream<MessageChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
                    let sessionID = try await resolveSessionID(for: project, sshSession: sshSession)
                    var accumulator = OpenCodeChatEventAccumulator(sessionID: sessionID)
                    let events = client.streamEvents(session: sshSession)

                    try await client.promptAsync(
                        sshSession: sshSession,
                        sessionID: sessionID,
                        payload: OpenCodePromptPayload(
                            messageID: messageId?.uuidString,
                            parts: [.text(text)]
                        ),
                        directory: project.path
                    )

                    for try await event in events {
                        let chunks = accumulator.consume(event)
                        for chunk in chunks {
                            continuation.yield(chunk)
                            if chunk.isComplete {
                                try? await hydrateOpenCodeState(project: project, sshSession: sshSession, sessionID: sessionID)
                                continuation.finish()
                                return
                            }
                        }
                    }

                    try? await hydrateOpenCodeState(project: project, sshSession: sshSession, sessionID: sessionID)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func hydrateMessages(for project: RemoteProject) async throws -> [CodingAgentRuntimeHydratedMessage] {
        guard let sessionID = sanitizedSessionID(project.openCodeSessionId) else {
            return []
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let messages = try await client.sessionMessages(
            sshSession: sshSession,
            sessionID: sessionID,
            directory: project.path
        )
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messages: messages))
        return OpenCodeChatMapper.hydratedMessages(from: messages)
    }

    func sessionState(for project: RemoteProject) async throws -> CodingAgentRuntimeSessionState {
        guard let sessionID = sanitizedSessionID(project.openCodeSessionId) else {
            return .idle(runtime: kind)
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let statuses = try await client.sessionStatus(sshSession: sshSession, directory: project.path)
        return .openCode(runtime: kind, rawStatus: statuses[sessionID]?.type)
    }

    func abort(project: RemoteProject) async throws {
        guard let sessionID = sanitizedSessionID(project.openCodeSessionId) else {
            throw CodingAgentRuntimeError.missingSession
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        _ = try await client.abortSession(sshSession: sshSession, sessionID: sessionID, directory: project.path)
    }

    func replyToPermission(
        project: RemoteProject,
        permissionId: String,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope,
        message: String?
    ) async throws {
        guard let sessionID = sanitizedSessionID(project.openCodeSessionId) else {
            throw CodingAgentRuntimeError.missingSession
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        try await client.replyPermission(
            sshSession: sshSession,
            sessionID: sessionID,
            permissionID: permissionId,
            response: openCodePermissionResponse(decision: decision, scope: scope),
            directory: project.path
        )
    }

    func reset(project: RemoteProject) async throws {
        project.resetOpenCodeRuntimeState()
    }

    private func resolveSessionID(for project: RemoteProject, sshSession: SSHSession) async throws -> String {
        if let existing = sanitizedSessionID(project.openCodeSessionId) {
            return existing
        }

        let created = try await client.createSession(
            sshSession: sshSession,
            title: project.displayTitle,
            directory: project.path
        )
        guard let sessionID = sanitizedSessionID(created.id) else {
            throw OpenCodeClientError.invalidResponse("OpenCode did not return a session id.")
        }
        project.openCodeSessionId = sessionID
        project.selectedAgentRuntime = .openCode
        project.updateLastModified()
        return sessionID
    }

    private func hydrateOpenCodeState(
        project: RemoteProject,
        sshSession: SSHSession,
        sessionID: String
    ) async throws {
        let messages = try await client.sessionMessages(
            sshSession: sshSession,
            sessionID: sessionID,
            directory: project.path
        )
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messages: messages))
    }

    private func sanitizedSessionID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func openCodePermissionResponse(decision: ToolApprovalDecision, scope: ToolApprovalScope) -> String {
        guard decision == .allow else { return "reject" }
        switch scope {
        case .once:
            return "once"
        case .agent, .global:
            return "always"
        }
    }
}

@MainActor
final class CodingAgentRuntimeRegistry {
    private let claudeRuntime: CodingAgentRuntimeService
    private let openCodeRuntime: CodingAgentRuntimeService

    init(
        claudeRuntime: CodingAgentRuntimeService? = nil,
        openCodeRuntime: CodingAgentRuntimeService? = nil
    ) {
        self.claudeRuntime = claudeRuntime ?? ClaudeProxyRuntimeService()
        self.openCodeRuntime = openCodeRuntime ?? OpenCodeRuntimeService()
    }

    func runtime(for kind: CodingAgentRuntimeKind) -> CodingAgentRuntimeService {
        switch kind {
        case .claudeProxy:
            return claudeRuntime
        case .openCode:
            return openCodeRuntime
        }
    }
}
