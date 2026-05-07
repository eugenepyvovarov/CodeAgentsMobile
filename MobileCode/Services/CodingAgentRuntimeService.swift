//
//  CodingAgentRuntimeService.swift
//  CodeAgentsMobile
//
//  Purpose: Runtime-neutral boundary for Claude proxy and OpenCode integrations
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
        // Keep the parameter for call-site compatibility; missing per-project runtime markers are legacy projects.
        _ = selectionStore
        guard let rawValue = project.agentRuntimeRawValue,
              let runtime = CodingAgentRuntimeKind(rawValue: rawValue) else {
            return .claudeProxy
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

struct OpenCodeRuntimeDiagnostics: Equatable, CustomStringConvertible {
    let eventPath: String
    let directory: String
    let sessionID: String
    let modelID: String?

    var description: String {
        var values = [
            "eventPath=\(eventPath)",
            "directory=\(directory)",
            "sessionID=\(sessionID)"
        ]
        if let modelID {
            values.append("modelID=\(modelID)")
        }
        return values.joined(separator: " ")
    }
}

enum OpenCodeRuntimeError: LocalizedError, Equatable {
    case streamAttachmentTimedOut(OpenCodeRuntimeDiagnostics)
    case streamEndedBeforePrompt(OpenCodeRuntimeDiagnostics)

    var errorDescription: String? {
        switch self {
        case .streamAttachmentTimedOut(let diagnostics):
            return "OpenCode event stream did not attach before sending the prompt. \(diagnostics.description)"
        case .streamEndedBeforePrompt(let diagnostics):
            return "OpenCode event stream ended before sending the prompt. \(diagnostics.description)"
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
    func replyToQuestion(project: RemoteProject, questionId: String, answers: [[String]]) async throws
    func rejectQuestion(project: RemoteProject, questionId: String) async throws
    func reset(project: RemoteProject) async throws
}

extension CodingAgentRuntimeService {
    var displayName: String { kind.displayName }

    func sessionState(for project: RemoteProject) async throws -> CodingAgentRuntimeSessionState {
        .idle(runtime: kind)
    }

    func replyToQuestion(project: RemoteProject, questionId: String, answers: [[String]]) async throws {
        throw CodingAgentRuntimeError.unsupported("This runtime does not support interactive questions.")
    }

    func rejectQuestion(project: RemoteProject, questionId: String) async throws {
        throw CodingAgentRuntimeError.unsupported("This runtime does not support interactive questions.")
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
    private let clientOverride: OpenCodeClient?
    private let streamAttachTimeoutNanoseconds: UInt64 = 5_000_000_000

    init(sshService: SSHService? = nil, client: OpenCodeClient? = nil) {
        self.sshService = sshService ?? .shared
        self.clientOverride = client
    }

    func health(for project: RemoteProject) async -> CodingAgentRuntimeHealth {
        do {
            let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
            let client = client(for: project)
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
                    let client = client(for: project)
                    let sessionID = try await resolveSessionID(for: project, sshSession: sshSession)
                    let promptModel = await resolvePromptModel(for: project, sshSession: sshSession)
                    var accumulator = OpenCodeChatEventAccumulator(sessionID: sessionID)
                    let eventPath = OpenCodeSessionPath.path("/event", directory: project.path)
                    let diagnostics = OpenCodeRuntimeDiagnostics(
                        eventPath: eventPath,
                        directory: project.path,
                        sessionID: sessionID,
                        modelID: promptModel?.fullID
                    )
                    let eventIterator = OpenCodeEventIterator(stream: client.streamEvents(session: sshSession, path: eventPath))
                    let firstEvent = try await waitForStreamAttachment(
                        eventIterator: eventIterator,
                        diagnostics: diagnostics
                    )
                    if case .serverConnected = firstEvent {
                        SSHLogger.log("OpenCode event stream attached: \(diagnostics.description)", level: .debug)
                    }

                    let prompt = try OpenCodePromptBuilder.build(
                        messageID: messageId?.uuidString,
                        composedPrompt: text,
                        projectPath: project.path,
                        model: promptModel
                    )
                    try await validatePromptReferences(prompt, sshSession: sshSession)
                    try await client.promptAsync(
                        sshSession: sshSession,
                        sessionID: sessionID,
                        payload: prompt.payload,
                        directory: project.path
                    )

                    func consume(_ event: OpenCodeEvent) async throws -> Bool {
                        let chunks = accumulator.consume(event)
                        for chunk in chunks {
                            continuation.yield(chunk)
                            if chunk.isComplete, OpenCodeStreamCompletionPolicy.shouldFinish(after: chunk) {
                                try? await hydrateOpenCodeState(project: project, sshSession: sshSession, sessionID: sessionID)
                                continuation.finish()
                                return true
                            }
                        }
                        return false
                    }

                    if case .serverConnected = firstEvent {
                    } else if try await consume(firstEvent) {
                        return
                    }

                    do {
                        while let event = try await eventIterator.next() {
                            if try await consume(event) {
                                return
                            }
                        }
                    } catch {
                        let fallbackChunks = (try? await fallbackHydrationChunks(
                            project: project,
                            sshSession: sshSession,
                            sessionID: sessionID
                        )) ?? []
                        if fallbackChunks.isEmpty {
                            throw error
                        }
                        for chunk in fallbackChunks {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        return
                    }

                    let fallbackChunks = try await fallbackHydrationChunks(
                        project: project,
                        sshSession: sshSession,
                        sessionID: sessionID
                    )
                    for chunk in fallbackChunks {
                        continuation.yield(chunk)
                    }
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
        let client = client(for: project)
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
        let client = client(for: project)
        let statuses = try await client.sessionStatus(sshSession: sshSession, directory: project.path)
        return .openCode(runtime: kind, rawStatus: statuses[sessionID]?.type)
    }

    func abort(project: RemoteProject) async throws {
        guard let sessionID = sanitizedSessionID(project.openCodeSessionId) else {
            throw CodingAgentRuntimeError.missingSession
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
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
        let client = client(for: project)
        try await client.replyPermission(
            sshSession: sshSession,
            sessionID: sessionID,
            permissionID: permissionId,
            response: openCodePermissionResponse(decision: decision, scope: scope),
            directory: project.path
        )
    }

    func replyToQuestion(project: RemoteProject, questionId: String, answers: [[String]]) async throws {
        guard sanitizedSessionID(project.openCodeSessionId) != nil else {
            throw CodingAgentRuntimeError.missingSession
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        try await client.replyQuestion(
            sshSession: sshSession,
            requestID: questionId,
            answers: answers,
            directory: project.path
        )
    }

    func rejectQuestion(project: RemoteProject, questionId: String) async throws {
        guard sanitizedSessionID(project.openCodeSessionId) != nil else {
            throw CodingAgentRuntimeError.missingSession
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        try await client.rejectQuestion(
            sshSession: sshSession,
            requestID: questionId,
            directory: project.path
        )
    }

    func reset(project: RemoteProject) async throws {
        project.resetOpenCodeRuntimeState()
    }

    private func resolveSessionID(for project: RemoteProject, sshSession: SSHSession) async throws -> String {
        if let existing = sanitizedSessionID(project.openCodeSessionId) {
            try? await ProxyTaskService.shared.recordActiveOpenCodeSession(project: project, sessionId: existing)
            return existing
        }

        let client = client(for: project)
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
        try? await ProxyTaskService.shared.recordActiveOpenCodeSession(project: project, sessionId: sessionID)
        return sessionID
    }

    private func resolvePromptModel(for project: RemoteProject, sshSession: SSHSession) async -> OpenCodePromptModel? {
        let profile = OpenCodeAIProviderSettingsStore().effectiveProfile(for: project.serverId)
        if let modelID = profile.resolvedModelID,
           let promptModel = OpenCodePromptModel(fullID: modelID) {
            return promptModel
        }

        for path in await modelConfigurationPaths(for: project, sshSession: sshSession) {
            guard let modelID = await selectedModelID(at: path, sshSession: sshSession),
                  let promptModel = OpenCodePromptModel(fullID: modelID) else {
                continue
            }
            return promptModel
        }

        return nil
    }

    private func modelConfigurationPaths(for project: RemoteProject, sshSession: SSHSession) async -> [String] {
        let projectPaths = [
            "\(project.path)/opencode.json",
            "\(project.path)/opencode.jsonc"
        ]

        let globalPath = await globalOpenCodeConfigurationPath(sshSession: sshSession)
        return projectPaths + [globalPath].compactMap { $0 }
    }

    private func globalOpenCodeConfigurationPath(sshSession: SSHSession) async -> String? {
        do {
            let command = "printf '%s' \"${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json\""
            let path = try await sshSession.execute(command)
            return nonEmptyString(path)
        } catch {
            SSHLogger.log("Unable to resolve OpenCode global config path: \(error.localizedDescription)", level: .debug)
            return nil
        }
    }

    private func selectedModelID(at path: String, sshSession: SSHSession) async -> String? {
        do {
            let json = try await sshSession.readFile(path)
            let document = try OpenCodeMCPConfigDocument(jsonString: json)
            return nonEmptyString(document.selectedModelID)
        } catch {
            let message = error.localizedDescription.lowercased()
            if !message.contains("no such file") && !message.contains("cannot open") {
                SSHLogger.log("Unable to read OpenCode model config at \(path): \(error.localizedDescription)", level: .debug)
            }
            return nil
        }
    }

    private func nonEmptyString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func hydrateOpenCodeState(
        project: RemoteProject,
        sshSession: SSHSession,
        sessionID: String
    ) async throws {
        let client = client(for: project)
        let messages = try await client.sessionMessages(
            sshSession: sshSession,
            sessionID: sessionID,
            directory: project.path
        )
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messages: messages))
    }

    private func fallbackHydrationChunks(
        project: RemoteProject,
        sshSession: SSHSession,
        sessionID: String
    ) async throws -> [MessageChunk] {
        let client = client(for: project)
        let previousState = project.openCodeHydrationState
        let messages = try await client.sessionMessages(
            sshSession: sshSession,
            sessionID: sessionID,
            directory: project.path
        )
        let diff = OpenCodeHydrationDiffer.diff(local: previousState, remoteMessages: messages)
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messages: messages))
        guard diff.hasChanges else {
            return []
        }

        return OpenCodeChatMapper.hydratedMessages(from: messages).compactMap { hydrated in
            let partIDs = Set(hydrated.runtimePartIDs)
            let hasNewParts = !partIDs.isDisjoint(with: diff.addedPartIDs)
            guard hydrated.role == .assistant,
                  diff.addedMessageIDs.contains(hydrated.runtimeMessageID) || hasNewParts else {
                return nil
            }

            var metadata: [String: Any] = [
                "type": "result",
                "runtime": CodingAgentRuntimeKind.openCode.rawValue,
                "opencodeSessionId": sessionID,
                "opencodeMessageId": hydrated.runtimeMessageID,
                "opencodePartIds": hydrated.runtimePartIDs,
                "result": hydrated.text,
                "content": [
                    [
                        "type": "text",
                        "text": hydrated.text
                    ]
                ]
            ]
            if let originalPayload = hydrated.originalPayload,
               let originalJSON = String(data: originalPayload, encoding: .utf8) {
                metadata["originalJSON"] = originalJSON
            }

            return MessageChunk(
                content: hydrated.text,
                isComplete: true,
                isError: false,
                metadata: metadata
            )
        }
    }

    private func waitForStreamAttachment(
        eventIterator: OpenCodeEventIterator,
        diagnostics: OpenCodeRuntimeDiagnostics
    ) async throws -> OpenCodeEvent {
        switch try await nextEventWithTimeout(from: eventIterator, timeoutNanoseconds: streamAttachTimeoutNanoseconds) {
        case .event(let event):
            return event
        case .ended:
            throw OpenCodeRuntimeError.streamEndedBeforePrompt(diagnostics)
        case .timedOut:
            throw OpenCodeRuntimeError.streamAttachmentTimedOut(diagnostics)
        }
    }

    private func nextEventWithTimeout(
        from iterator: OpenCodeEventIterator,
        timeoutNanoseconds: UInt64
    ) async throws -> OpenCodeTimedEvent {
        try await withThrowingTaskGroup(of: OpenCodeTimedEvent.self) { group in
            group.addTask {
                if let event = try await iterator.next() {
                    return .event(event)
                }
                return .ended
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }

            guard let result = try await group.next() else {
                return .ended
            }
            group.cancelAll()
            return result
        }
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

    private func client(for project: RemoteProject) -> OpenCodeClient {
        clientOverride ?? OpenCodeClientFactory.client(for: project.serverId)
    }

    private func validatePromptReferences(
        _ prompt: OpenCodePromptBuildResult,
        sshSession: SSHSession
    ) async throws {
        if let skillReference = prompt.skillReference {
            let checks = skillReference.skillFilePaths
                .map { "[ -f \(shellEscaped($0)) ]" }
                .joined(separator: " || ")
            let command = "if \(checks); then echo EXISTS; else echo MISSING; fi"
            let output = try await sshSession.execute(command)
            guard output.contains("EXISTS") else {
                throw OpenCodePromptBuildError.missingSkill(
                    slug: skillReference.slug,
                    checkedPaths: skillReference.skillFilePaths
                )
            }
        }

        for file in prompt.fileReferences {
            let command = "[ -f \(shellEscaped(file.absolutePath)) ] && echo EXISTS || echo MISSING"
            let output = try await sshSession.execute(command)
            guard output.contains("EXISTS") else {
                throw OpenCodePromptBuildError.missingAttachment(file.absolutePath)
            }
        }
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}

private enum OpenCodeTimedEvent {
    case event(OpenCodeEvent)
    case ended
    case timedOut
}

enum OpenCodeStreamCompletionPolicy {
    static func shouldFinish(after chunk: MessageChunk) -> Bool {
        if chunk.isError {
            return true
        }

        let type = chunk.metadata?["type"] as? String
        return type != "opencode_tool"
            && type != "opencode_progress"
            && type != "tool_permission"
            && type != "opencode_question"
    }
}

private actor OpenCodeEventIterator {
    private var iterator: AsyncThrowingStream<OpenCodeEvent, Error>.Iterator

    init(stream: AsyncThrowingStream<OpenCodeEvent, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> OpenCodeEvent? {
        var activeIterator = iterator
        let event = try await activeIterator.next()
        iterator = activeIterator
        return event
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
