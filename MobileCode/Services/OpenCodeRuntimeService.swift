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
    case streamEndedBeforeCompletion(OpenCodeRuntimeDiagnostics)

    var errorDescription: String? {
        switch self {
        case .streamAttachmentTimedOut(let diagnostics):
            return "OpenCode event stream did not attach before sending the prompt (server may be slow or /event stalled). \(diagnostics.description)"
        case .streamEndedBeforePrompt(let diagnostics):
            return "OpenCode event stream ended before sending the prompt (check OpenCode service on the host). \(diagnostics.description)"
        case .streamEndedBeforeCompletion(let diagnostics):
            return "OpenCode event stream ended before the submitted reply was finalized. \(diagnostics.description)"
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
    private var activeSendsByProjectID: [UUID: ActiveOpenCodeSend] = [:]

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
        let sendToken = UUID()
        let initialPromptMessageID = Self.makePromptMessageID(from: messageId)
        return AsyncThrowingStream { continuation in
            let lifetime = OpenCodeSendStreamLifetime()
            lifetime.task = Task {
                activeSendsByProjectID[project.id] = ActiveOpenCodeSend(
                    token: sendToken,
                    latestPromptMessageID: initialPromptMessageID
                )
                defer {
                    if activeSendsByProjectID[project.id]?.token == sendToken {
                        activeSendsByProjectID.removeValue(forKey: project.id)
                    }
                }
                do {
                    try Task.checkCancellation()
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

                    try await submitPromptPayload(
                        text,
                        project: project,
                        messageID: initialPromptMessageID,
                        sshSession: sshSession,
                        client: client,
                        sessionID: sessionID,
                        promptModel: promptModel,
                        promptVariant: promptVariant
                    )

                    // After session.idle / final answer, keep `/event` open briefly so a
                    // soft-steered follow-up (prompt_async mid-run) can resume before we detach.
                    var awaitingIdleGrace = false

                    @MainActor
                    func finishStreamSuccessfully() async throws {
                        let expectedParentID = activeSendsByProjectID[project.id]?.latestPromptMessageID
                            ?? initialPromptMessageID
                        let messages = try await hydrateOpenCodeState(
                            project: project,
                            sshSession: sshSession,
                            sessionID: sessionID
                        )
                        let exactReplyIDs = OpenCodeReplyFinality.finalizedRenderableAssistantMessageIDs(
                            in: messages,
                            parentMessageID: expectedParentID
                        )
                        guard !exactReplyIDs.isEmpty else {
                            throw OpenCodeRuntimeError.streamEndedBeforeCompletion(diagnostics)
                        }
                        for chunk in hydrationChunks(
                            from: messages,
                            sessionID: sessionID,
                            diff: nil,
                            exactReplyIDs: exactReplyIDs
                        ) {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    }

                    /// Returns whether the send stream should end immediately (errors only).
                    /// Non-error completion arms a short grace window instead of detaching.
                    func consume(_ event: OpenCodeEvent) async throws -> Bool {
                        try Task.checkCancellation()
                        let chunks = accumulator.consume(event)
                        if chunks.isEmpty { return false }

                        var sawTerminalComplete = false
                        for chunk in chunks {
                            continuation.yield(chunk)
                            if chunk.isComplete, OpenCodeStreamCompletionPolicy.shouldFinish(after: chunk) {
                                if chunk.isError {
                                    try? await hydrateOpenCodeState(
                                        project: project,
                                        sshSession: sshSession,
                                        sessionID: sessionID
                                    )
                                    continuation.finish()
                                    return true
                                }
                                sawTerminalComplete = true
                            } else {
                                // Further tool/text/progress after a prior idle means the run continued
                                // (typical soft-steer). Cancel the grace detach.
                                awaitingIdleGrace = false
                                sawTerminalComplete = false
                            }
                        }
                        if sawTerminalComplete {
                            awaitingIdleGrace = true
                        }
                        return false
                    }

                    if case .serverConnected = firstEvent {
                    } else if try await consume(firstEvent) {
                        return
                    }

                    do {
                        while true {
                            let timed: OpenCodeTimedEvent
                            if awaitingIdleGrace {
                                timed = try await nextEventWithTimeout(
                                    from: eventIterator,
                                    timeoutNanoseconds: OpenCodeStreamCompletionPolicy.idleGraceNanoseconds
                                )
                            } else if let event = try await eventIterator.next() {
                                timed = .event(event)
                            } else {
                                timed = .ended
                            }

                            switch timed {
                            case .event(let event):
                                if try await consume(event) {
                                    return
                                }
                            case .timedOut:
                                // Grace expired with no further activity after a final answer.
                                try await finishStreamSuccessfully()
                                return
                            case .ended:
                                let expectedParentID = activeSendsByProjectID[project.id]?.latestPromptMessageID
                                    ?? initialPromptMessageID
                                let fallback = try await fallbackHydrationChunks(
                                    project: project,
                                    sshSession: sshSession,
                                    sessionID: sessionID,
                                    expectedParentMessageID: expectedParentID
                                )
                                for chunk in fallback.chunks {
                                    continuation.yield(chunk)
                                }
                                guard fallback.hasFinalizedExpectedReply else {
                                    throw OpenCodeRuntimeError.streamEndedBeforeCompletion(diagnostics)
                                }
                                continuation.finish()
                                return
                            }
                        }
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        let expectedParentID = activeSendsByProjectID[project.id]?.latestPromptMessageID
                            ?? initialPromptMessageID
                        let fallback = try? await fallbackHydrationChunks(
                            project: project,
                            sshSession: sshSession,
                            sessionID: sessionID,
                            expectedParentMessageID: expectedParentID
                        )
                        guard let fallback, fallback.hasFinalizedExpectedReply else {
                            throw error
                        }
                        for chunk in fallback.chunks {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        return
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                lifetime.cancel()
            }
        }
    }

    /// Soft-steer: inject a new user prompt into the active OpenCode session without attaching `/event`.
    /// OpenCode's agent loop picks up the newest user message at the next step boundary.
    func submitPrompt(
        _ text: String,
        in project: RemoteProject,
        messageId: UUID? = nil,
        mcpServers: [MCPServer] = []
    ) async throws {
        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        let sessionID = try await resolveSessionID(for: project, sshSession: sshSession)
        let promptModel = await resolvePromptModel(for: project, sshSession: sshSession)
        let promptVariant = resolvePromptVariant(for: project)
        let promptMessageID = Self.makePromptMessageID(from: messageId)
        let previousSend = activeSendsByProjectID[project.id]
        if var activeSend = previousSend {
            activeSend.latestPromptMessageID = promptMessageID
            activeSendsByProjectID[project.id] = activeSend
        }
        do {
            try await submitPromptPayload(
                text,
                project: project,
                messageID: promptMessageID,
                sshSession: sshSession,
                client: client,
                sessionID: sessionID,
                promptModel: promptModel,
                promptVariant: promptVariant
            )
        } catch {
            if activeSendsByProjectID[project.id]?.token == previousSend?.token {
                activeSendsByProjectID[project.id] = previousSend
            }
            throw error
        }
    }

    private func submitPromptPayload(
        _ text: String,
        project: RemoteProject,
        messageID: String,
        sshSession: SSHSession,
        client: OpenCodeClient,
        sessionID: String,
        promptModel: OpenCodePromptModel?,
        promptVariant: String?
    ) async throws {
        let prompt = try OpenCodePromptBuilder.build(
            messageID: messageID,
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
                diff: OpenCodeHydrationDiffer.diff(local: state, remote: state),
                canonicalAssistantCount: nil
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
        // Compute next anchors but do NOT persist yet — ChatViewModel advances after
        // successful merge + save so a crash cannot leave anchors ahead of durable messages.
        let storedState = OpenCodeHydrationDiffer.mergedState(
            local: previousState,
            observedMessages: messages,
            mode: mode
        )
        try Task.checkCancellation()
        let mapperStart = DispatchTime.now().uptimeNanoseconds
        let hydratedMessages = OpenCodeChatMapper.hydratedMessages(from: selectedMessages)
        let canonicalAssistantIDs: Set<String>?
        if mode.replacesStoredState || mode.limit.map({ messages.count < $0 }) == true {
            canonicalAssistantIDs = OpenCodeChatMapper.finalizedRenderableAssistantMessageIDs(from: messages)
        } else {
            canonicalAssistantIDs = nil
        }
        if let canonicalAssistantIDs {
            project.updateOpenCodeCanonicalAssistantMessages(
                ids: canonicalAssistantIDs,
                sessionID: sessionID
            )
        }
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
            diff: diff,
            canonicalAssistantCount: canonicalAssistantIDs?.count
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

    func fetchPendingPermissions(project: RemoteProject) async throws -> [OpenCodePendingPermission] {
        let sshSession = try await sshService.getConnection(for: project, purpose: .opencode)
        let client = client(for: project)
        return try await client.listPermissions(sshSession: sshSession, directory: project.path)
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
            // Re-pin is for scheduled tasks / daemon only — not required for this chat stream.
            // Defer so text send is not blocked on a second SSH+daemon round-trip.
            scheduleActiveSessionRepin(project: project, sessionId: existing)
            return existing
        }

        // Drop placeholders / stale local ids (e.g. ses_diag) so we create a real session.
        if project.openCodeSessionId != nil {
            project.openCodeSessionId = nil
            project.openCodeCanonicalAssistantMessageIds = []
            project.openCodeCanonicalAssistantSessionId = nil
            project.updateLastModified()
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
        project.openCodeCanonicalAssistantMessageIds = []
        project.openCodeCanonicalAssistantSessionId = sessionID
        project.selectedAgentRuntime = .openCode
        project.updateLastModified()
        // First pin for a newly created session: await so schedulers see it promptly.
        try? await ProxyTaskService.shared.recordActiveOpenCodeSession(project: project, sessionId: sessionID)
        return sessionID
    }

    /// Best-effort daemon re-pin off the send critical path.
    ///
    /// The active-session endpoint is last-write-wins. A pre-check alone is not enough: the
    /// daemon POST can still complete after clear chat / new session, leaving scheduled tasks
    /// pinned to a stale OpenCode conversation. Always reconcile after the write.
    private func scheduleActiveSessionRepin(project: RemoteProject, sessionId: String) {
        let expectedSessionId = sessionId
        Task { @MainActor in
            guard OpenCodeSessionID.sanitize(project.openCodeSessionId) == expectedSessionId else {
                return
            }
            try? await ProxyTaskService.shared.recordActiveOpenCodeSession(
                project: project,
                sessionId: expectedSessionId
            )
            await reconcileActiveSessionPin(project: project, writtenSessionId: expectedSessionId)
        }
    }

    /// Repair a daemon pin if local session state changed while the write was in flight.
    private func reconcileActiveSessionPin(project: RemoteProject, writtenSessionId: String) async {
        let current = OpenCodeSessionID.sanitize(project.openCodeSessionId)
        switch OpenCodeActiveSessionPinReconcile.action(
            writtenSessionId: writtenSessionId,
            currentSessionId: current
        ) {
        case .none:
            return
        case .pin(let sessionId):
            try? await ProxyTaskService.shared.recordActiveOpenCodeSession(
                project: project,
                sessionId: sessionId
            )
        case .clear:
            try? await ProxyTaskService.shared.clearActiveOpenCodeSession(project: project)
        }
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

    private static func makePromptMessageID(from value: UUID?) -> String {
        let uuid = (value ?? UUID()).uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return "msg_\(uuid)"
    }

    @discardableResult
    private func hydrateOpenCodeState(
        project: RemoteProject,
        sshSession: SSHSession,
        sessionID: String
    ) async throws -> [OpenCodeSessionMessage] {
        let client = client(for: project)
        let messages = try await client.sessionMessages(
            sshSession: sshSession,
            sessionID: sessionID,
            directory: project.path
        )
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messages: messages))
        project.updateOpenCodeCanonicalAssistantMessages(
            ids: OpenCodeChatMapper.finalizedRenderableAssistantMessageIDs(from: messages),
            sessionID: sessionID
        )
        return messages
    }

    private func fallbackHydrationChunks(
        project: RemoteProject,
        sshSession: SSHSession,
        sessionID: String,
        expectedParentMessageID: String
    ) async throws -> OpenCodeFallbackHydration {
        let client = client(for: project)
        let previousState = project.openCodeHydrationState
        let messages = try await client.sessionMessages(
            sshSession: sshSession,
            sessionID: sessionID,
            directory: project.path
        )
        let diff = OpenCodeHydrationDiffer.diff(local: previousState, remoteMessages: messages)
        project.updateOpenCodeHydrationState(OpenCodeHydrationState(messages: messages))
        project.updateOpenCodeCanonicalAssistantMessages(
            ids: OpenCodeChatMapper.finalizedRenderableAssistantMessageIDs(from: messages),
            sessionID: sessionID
        )
        let exactReplyIDs = OpenCodeReplyFinality.finalizedRenderableAssistantMessageIDs(
            in: messages,
            parentMessageID: expectedParentMessageID
        )
        let hasFinalizedExpectedReply = !exactReplyIDs.isEmpty
        guard diff.hasChanges || !exactReplyIDs.isEmpty else {
            return OpenCodeFallbackHydration(
                chunks: [],
                hasFinalizedExpectedReply: hasFinalizedExpectedReply
            )
        }

        let chunks = hydrationChunks(
            from: messages,
            sessionID: sessionID,
            diff: diff,
            exactReplyIDs: exactReplyIDs
        )
        return OpenCodeFallbackHydration(
            chunks: chunks,
            hasFinalizedExpectedReply: hasFinalizedExpectedReply
        )
    }

    private func hydrationChunks(
        from messages: [OpenCodeSessionMessage],
        sessionID: String,
        diff: OpenCodeHydrationDiff?,
        exactReplyIDs: Set<String>
    ) -> [MessageChunk] {
        OpenCodeChatMapper.hydratedMessages(from: messages).compactMap { hydrated -> MessageChunk? in
            let partIDs = Set(hydrated.runtimePartIDs)
            let hasNewParts = diff.map { !partIDs.isDisjoint(with: $0.addedPartIDs) } ?? false
            let hasUpdatedParts = diff.map { !partIDs.isDisjoint(with: $0.updatedPartIDs) } ?? false
            let isExactReply = exactReplyIDs.contains(hydrated.runtimeMessageID)
            guard hydrated.role == .assistant,
                  isExactReply
                    || diff?.addedMessageIDs.contains(hydrated.runtimeMessageID) == true
                    || hasNewParts
                    || hasUpdatedParts else {
                return nil
            }

            var metadata: [String: Any] = [
                "type": hydrated.isComplete ? "result" : "assistant",
                "runtime": CodingAgentRuntimeKind.openCode.rawValue,
                "opencodeSessionId": sessionID,
                "opencodeMessageId": hydrated.runtimeMessageID,
                "opencodePartIds": hydrated.runtimePartIDs,
                "opencodeSubmittedReply": isExactReply,
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
                isComplete: hydrated.isComplete,
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
                case .streamEndedBeforeCompletion:
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
        OpenCodeSessionID.sanitize(value)
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
        let skillPaths = prompt.skillReference?.skillFilePaths ?? []
        let filePaths = prompt.fileReferences.map(\.absolutePath)
        guard !skillPaths.isEmpty || !filePaths.isEmpty else { return }

        let command = OpenCodePromptReferenceValidator.shellCommand(
            skillPaths: skillPaths,
            filePaths: filePaths,
            escape: shellEscaped
        )
        let output = try await sshSession.execute(command)
        if let error = OpenCodePromptReferenceValidator.parseFailure(
            output: output,
            skillSlug: prompt.skillReference?.slug,
            skillPaths: skillPaths,
            filePaths: filePaths
        ) {
            throw error
        }
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}

/// Decides how to repair a daemon active-session pin after an async write may have raced.
enum OpenCodeActiveSessionPinReconcile {
    enum Action: Equatable {
        case none
        case pin(String)
        case clear
    }

    static func action(writtenSessionId: String, currentSessionId: String?) -> Action {
        if currentSessionId == writtenSessionId {
            return .none
        }
        if let currentSessionId {
            return .pin(currentSessionId)
        }
        return .clear
    }
}

/// Batches skill (OR) + attachment (AND) existence checks into one remote shell invocation.
///
/// The script is POSIX/`bash` syntax. `SSHSession.execute` runs commands via the user's login
/// shell (`$SHELL -l -c`), which may be fish — so the body is always wrapped in `bash -c`.
enum OpenCodePromptReferenceValidator {
    static func shellCommand(
        skillPaths: [String],
        filePaths: [String],
        escape: (String) -> String
    ) -> String {
        var lines: [String] = ["set +e"]

        if !skillPaths.isEmpty {
            let checks = skillPaths.map { "[ -f \(escape($0)) ]" }.joined(separator: " || ")
            lines.append("if \(checks); then :; else echo MISSING_SKILL; exit 0; fi")
        }

        for (index, path) in filePaths.enumerated() {
            lines.append(
                "if [ -f \(escape(path)) ]; then :; else echo MISSING_FILE:\(index); exit 0; fi"
            )
        }

        lines.append("echo OK")
        let script = lines.joined(separator: "; ")
        // Force bash so fish (and other non-POSIX login shells) do not parse `if`/`fi`/`set +e`.
        return "bash -c \(SSHShellQuoting.quote(script))"
    }

    static func parseFailure(
        output: String,
        skillSlug: String?,
        skillPaths: [String],
        filePaths: [String]
    ) -> OpenCodePromptBuildError? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("MISSING_SKILL") {
            return .missingSkill(slug: skillSlug ?? "", checkedPaths: skillPaths)
        }
        if let range = trimmed.range(of: "MISSING_FILE:") {
            let indexText = String(trimmed[range.upperBound...])
                .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
                .first
                .map(String.init) ?? ""
            if let index = Int(indexText), filePaths.indices.contains(index) {
                return .missingAttachment(filePaths[index])
            }
            return .missingAttachment(indexText.isEmpty ? trimmed : indexText)
        }
        // Success marker from the remote script.
        if trimmed.contains("OK") {
            return nil
        }
        // No OK and no structured miss — fail closed so we do not prompt with missing files.
        return .missingAttachment(filePaths.first ?? "unknown")
    }
}

private enum OpenCodeTimedEvent {
    case event(OpenCodeEvent)
    case ended
    case timedOut
}

private struct ActiveOpenCodeSend {
    let token: UUID
    var latestPromptMessageID: String
}

private struct OpenCodeFallbackHydration {
    let chunks: [MessageChunk]
    let hasFinalizedExpectedReply: Bool
}

enum OpenCodeReplyFinality {
    static func finalizedRenderableAssistantMessageIDs(
        in messages: [OpenCodeSessionMessage],
        parentMessageID: String
    ) -> Set<String> {
        Set(messages.compactMap { message in
            guard message.info.role == "assistant",
                  message.info.parentID == parentMessageID,
                  message.info.time?.completed != nil,
                  !OpenCodeChatMapper.renderedText(from: message.parts).isEmpty else {
                return nil
            }
            return message.info.id
        })
    }

    static func hasFinalizedRenderableAssistant(
        in messages: [OpenCodeSessionMessage],
        parentMessageID: String
    ) -> Bool {
        !finalizedRenderableAssistantMessageIDs(
            in: messages,
            parentMessageID: parentMessageID
        ).isEmpty
    }
}

/// Cancels the in-flight send-stream Task when the AsyncThrowingStream consumer ends or is cancelled.
private final class OpenCodeSendStreamLifetime: @unchecked Sendable {
    var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
    }
}

enum OpenCodeStreamCompletionPolicy {
    /// How long to keep `/event` open after a terminal answer chunk so soft-steered
    /// follow-ups (`prompt_async` while a stream is live) can produce more events.
    static let idleGraceNanoseconds: UInt64 = 2_500_000_000

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
