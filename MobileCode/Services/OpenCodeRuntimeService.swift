//
//  OpenCodeRuntimeService.swift
//  CodeAgentsMobile
//
//  Purpose: OpenCode runtime implementation (health, send/stream, hydrate, permissions).
//

import Foundation

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
            return "OpenCode event stream did not attach before sending the prompt (server may be slow or /event stalled). \(diagnostics.description)"
        case .streamEndedBeforePrompt(let diagnostics):
            return "OpenCode event stream ended before sending the prompt (check OpenCode service on the host). \(diagnostics.description)"
        }
    }
}

@MainActor
final class OpenCodeRuntimeService: CodingAgentRuntimeService {
    let kind = CodingAgentRuntimeKind.openCode

    /// How long to wait for the first SSE event on `/event` before treating attach as failed.
    /// Slow hosts / fresh OpenCode processes often need more than a few seconds.
    static let defaultStreamAttachTimeoutNanoseconds: UInt64 = 20_000_000_000
    /// Extra attach attempts after the first timeout (total attempts = 1 + this value).
    static let defaultStreamAttachRetryCount = 1

    private let sshService: SSHConnectionProviding
    private let clientOverride: OpenCodeClient?
    private let streamAttachTimeoutNanoseconds: UInt64
    private let streamAttachRetryCount: Int

    init(
        sshService: SSHConnectionProviding? = nil,
        client: OpenCodeClient? = nil,
        streamAttachTimeoutNanoseconds: UInt64 = OpenCodeRuntimeService.defaultStreamAttachTimeoutNanoseconds,
        streamAttachRetryCount: Int = OpenCodeRuntimeService.defaultStreamAttachRetryCount
    ) {
        self.sshService = sshService ?? SSHService.shared
        self.clientOverride = client
        self.streamAttachTimeoutNanoseconds = streamAttachTimeoutNanoseconds
        self.streamAttachRetryCount = max(0, streamAttachRetryCount)
    }

    func health(for project: RemoteProject) async -> CodingAgentRuntimeHealth {
        do {
            return try await probeHealth(for: project, allowRetry: true)
        } catch {
            return .unavailable(runtime: kind, message: error.localizedDescription)
        }
    }

    /// Soft-retry once on transient NIOSSH / direct-TCP blips with a fresh pooled session.
    private func probeHealth(for project: RemoteProject, allowRetry: Bool) async throws -> CodingAgentRuntimeHealth {
        do {
            let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
            let client = client(for: project)
            let health = try await client.health(session: sshSession)
            return health.healthy
                ? .available(runtime: kind, version: health.version)
                : .unavailable(runtime: kind, message: "OpenCode server reported unhealthy.")
        } catch {
            guard allowRetry, OpenCodeInstallerService.isTransientHealthFailure(error) else {
                throw error
            }
            SSHLogger.log(
                "OpenCode runtime health transient failure; retrying with fresh session: \(error.localizedDescription)",
                level: .warning
            )
            if let concrete = sshService as? SSHService {
                // Drop dead pooled logins, then force a fresh session for this purpose on the server.
                concrete.pruneDeadConnections()
                concrete.closeConnections(projectId: project.id, purpose: .opencode)
                concrete.closeConnections(serverId: project.serverId, purpose: .opencode)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            return try await probeHealth(for: project, allowRetry: false)
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
                    let promptVariant = resolvePromptVariant(for: project)
                    var accumulator = OpenCodeChatEventAccumulator(sessionID: sessionID)
                    let eventPath = OpenCodeSessionPath.path("/event", directory: project.path)
                    let diagnostics = OpenCodeRuntimeDiagnostics(
                        eventPath: eventPath,
                        directory: project.path,
                        sessionID: sessionID,
                        modelID: promptModel?.fullID
                    )
                    let (eventIterator, firstEvent) = try await attachEventStream(
                        client: client,
                        sshSession: sshSession,
                        eventPath: eventPath,
                        diagnostics: diagnostics
                    )
                    if case .serverConnected = firstEvent {
                        SSHLogger.log("OpenCode event stream attached: \(diagnostics.description)", level: .debug)
                    }

                    let prompt = try OpenCodePromptBuilder.build(
                        messageID: messageId?.uuidString,
                        composedPrompt: text,
                        projectPath: project.path,
                        model: promptModel,
                        variant: promptVariant
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
        try await hydrateMessages(for: project, mode: .initialBounded()).hydratedMessages
    }

    func hydrateMessages(
        for project: RemoteProject,
        mode: OpenCodeHydrationMode
    ) async throws -> OpenCodeHydrationResult {
        guard let sessionID = sanitizedSessionID(project.openCodeSessionId) else {
            let state = project.openCodeHydrationState
            return OpenCodeHydrationResult(
                mode: mode,
                fetchedCount: 0,
                selectedCount: 0,
                hydratedMessages: [],
                previousState: state,
                observedState: OpenCodeHydrationState(),
                storedState: state,
                diff: OpenCodeHydrationDiffer.diff(local: state, remote: state)
            )
        }

        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        let previousState = project.openCodeHydrationState
        let fetchStart = DispatchTime.now().uptimeNanoseconds
        let messages: [OpenCodeSessionMessage]
        do {
            messages = try await client.sessionMessages(
                sshSession: sshSession,
                sessionID: sessionID,
                directory: project.path,
                limit: mode.limit
            )
            ChatRecoveryTiming.log(
                runtime: kind.rawValue,
                projectID: project.id.uuidString,
                operation: "opencode.sessionMessages.fetch.\(mode.timingName)",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - fetchStart,
                metadata: [
                    "bounded": .flag(mode.limit != nil),
                    "limit": .count(mode.limit ?? 0),
                    "remoteMessages": .count(messages.count),
                    "status": .status(.complete)
                ]
            )
        } catch {
            ChatRecoveryTiming.log(
                runtime: kind.rawValue,
                projectID: project.id.uuidString,
                operation: "opencode.sessionMessages.fetch.\(mode.timingName)",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - fetchStart,
                metadata: [
                    "bounded": .flag(mode.limit != nil),
                    "limit": .count(mode.limit ?? 0),
                    "status": .status(.failed)
                ]
            )
            throw error
        }
        let observedState = OpenCodeHydrationState(messages: messages)
        let diff = OpenCodeHydrationDiffer.diff(local: previousState, remoteMessages: messages)
        let selectedMessages = OpenCodeHydrationDiffer.messagesNeedingHydration(
            local: previousState,
            remoteMessages: messages
        )
        let storedState = OpenCodeHydrationDiffer.mergedState(
            local: previousState,
            observedMessages: messages,
            mode: mode
        )
        try Task.checkCancellation()
        project.updateOpenCodeHydrationState(storedState)
        let mapperStart = DispatchTime.now().uptimeNanoseconds
        let hydratedMessages = OpenCodeChatMapper.hydratedMessages(from: selectedMessages)
        ChatRecoveryTiming.log(
            runtime: kind.rawValue,
            projectID: project.id.uuidString,
            operation: "opencode.sessionMessages.map.\(mode.timingName)",
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - mapperStart,
            metadata: [
                "addedMessages": .count(diff.addedMessageIDs.count),
                "addedParts": .count(diff.addedPartIDs.count),
                "bounded": .flag(mode.limit != nil),
                "hydratedMessages": .count(hydratedMessages.count),
                "remoteMessages": .count(messages.count),
                "selectedMessages": .count(selectedMessages.count),
                "status": .status(.complete)
            ]
        )
        return OpenCodeHydrationResult(
            mode: mode,
            fetchedCount: messages.count,
            selectedCount: selectedMessages.count,
            hydratedMessages: hydratedMessages,
            previousState: previousState,
            observedState: observedState,
            storedState: storedState,
            diff: diff
        )
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

    /// Ensures a durable OpenCode session id exists for the project (create if missing).
    @discardableResult
    func ensureSession(for project: RemoteProject) async throws -> String {
        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        return try await resolveSessionID(for: project, sshSession: sshSession)
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

    private func resolvePromptVariant(for project: RemoteProject) -> String? {
        OpenCodeAIProviderSettingsStore().effectiveProfile(for: project.serverId).resolvedVariant
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

    /// Opens `/event` and waits for the first SSE payload, retrying on attach timeout.
    private func attachEventStream(
        client: OpenCodeClient,
        sshSession: SSHSession,
        eventPath: String,
        diagnostics: OpenCodeRuntimeDiagnostics
    ) async throws -> (OpenCodeEventIterator, OpenCodeEvent) {
        let attempts = 1 + streamAttachRetryCount
        var lastError: Error?

        for attempt in 1...attempts {
            let eventIterator = OpenCodeEventIterator(
                stream: client.streamEvents(session: sshSession, path: eventPath)
            )
            do {
                let firstEvent = try await waitForStreamAttachment(
                    eventIterator: eventIterator,
                    diagnostics: diagnostics
                )
                if attempt > 1 {
                    SSHLogger.log(
                        "OpenCode event stream attached on retry \(attempt)/\(attempts): \(diagnostics.description)",
                        level: .info
                    )
                }
                return (eventIterator, firstEvent)
            } catch let error as OpenCodeRuntimeError {
                lastError = error
                switch error {
                case .streamAttachmentTimedOut, .streamEndedBeforePrompt:
                    if attempt < attempts {
                        SSHLogger.log(
                            "OpenCode event stream attach failed (attempt \(attempt)/\(attempts)), retrying: \(error.localizedDescription)",
                            level: .warning
                        )
                        continue
                    }
                    throw error
                }
            }
        }

        throw lastError ?? OpenCodeRuntimeError.streamAttachmentTimedOut(diagnostics)
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
