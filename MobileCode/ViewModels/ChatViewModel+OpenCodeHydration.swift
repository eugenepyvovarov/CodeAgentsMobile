//
//  ChatViewModel+OpenCodeHydration.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel OpenCode message hydration & session reconcile
//

import SwiftUI
import Observation
import SwiftData

extension ChatViewModel {
    func updateOpenCodeMessage(_ message: Message, with chunk: MessageChunk) {
        let originalJSON = (chunk.metadata?["originalJSON"] as? String)?.data(using: .utf8)
        let content = chunk.content.isEmpty ? message.content : chunk.content
        updateMessageWithJSON(message, content: content, originalJSON: originalJSON, replaceOriginalJSON: true)
        message.isStreaming = !chunk.isComplete
        message.isComplete = chunk.isComplete
        message.openCodeRuntimeFinalized = chunk.isComplete && !chunk.isError

        if chunk.isComplete, let project = ProjectContext.shared.activeProject {
            prefetchCodeAgentsUIMedia(in: project, messages: [message])
        }
    }

    func updateOpenCodeMessage(_ message: Message, with hydrated: CodingAgentRuntimeHydratedMessage) {
        updateMessageWithJSON(
            message,
            content: hydrated.text.isEmpty ? message.content : hydrated.text,
            originalJSON: hydrated.originalPayload,
            replaceOriginalJSON: true
        )
        message.isStreaming = !hydrated.isComplete
        message.isComplete = hydrated.isComplete
        message.openCodeRuntimeFinalized = hydrated.isComplete
    }


    /// Non-blocking hydrate for idle reopens with local history (does not delay deferred startup).
    func scheduleOpenCodeBackgroundHydration(project: RemoteProject) {
        openCodeFullHydrationTask?.cancel()
        let projectID = project.id
        let generation = openCodeHydrationGeneration
        openCodeFullHydrationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard self.ownsOpenCodeWork(projectID: projectID, generation: generation, kind: .hydration) else { return }
            await self.hydrateOpenCodeMessagesIfNeeded(project: project)
        }
        ChatRecoveryTiming.log(
            runtime: CodingAgentRuntimeKind.openCode.rawValue,
            projectID: projectID.uuidString,
            operation: "opencode.hydrateMessages.backgroundScheduled",
            elapsedNanoseconds: 0,
            metadata: [
                "localMessages": .count(messages.count),
                "status": .status(.started)
            ]
        )
    }

    func hydrateOpenCodeMessagesIfNeeded(project: RemoteProject) async {
        guard activeRuntimeKind(for: project) == .openCode else { return }
        guard project.openCodeSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }

        let ownedProjectID = project.id
        let generation = openCodeHydrationGeneration

        do {
            let runtime = runtimeRegistry.runtime(for: .openCode)
            let sessionStateStart = DispatchTime.now().uptimeNanoseconds
            let sessionState: CodingAgentRuntimeSessionState
            do {
                sessionState = try await runtime.sessionState(for: project)
                guard ownsOpenCodeWork(projectID: ownedProjectID, generation: generation, kind: .hydration) else { return }
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.sessionState",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - sessionStateStart,
                    metadata: [
                        "localMessages": .count(messages.count),
                        "sessionStatus": .status(timingStatus(for: sessionState.status)),
                        "status": .status(.complete)
                    ]
                )
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.sessionState",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - sessionStateStart,
                    metadata: [
                        "localMessages": .count(messages.count),
                        "status": .status(.failed)
                    ]
                )
                throw error
            }

            let showVisibleRecovery: Bool
            switch sessionState.status {
            case .busy, .retrying:
                showVisibleRecovery = true
            case .idle, .unknown:
                showVisibleRecovery = false
            }
            if showVisibleRecovery {
                isLoadingPreviousSession = true
            }
            defer {
                if showVisibleRecovery {
                    isLoadingPreviousSession = false
                }
            }

            let hydrateStart = DispatchTime.now().uptimeNanoseconds
            let hydrationResult: OpenCodeHydrationResult
            do {
                hydrationResult = try await runtime.hydrateMessages(for: project, mode: .initialBounded())
                guard ownsOpenCodeWork(projectID: ownedProjectID, generation: generation, kind: .hydration) else { return }
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.\(hydrationResult.mode.timingName)",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - hydrateStart,
                    metadata: [
                        "fetchedMessages": .count(hydrationResult.fetchedCount),
                        "hydratedMessages": .count(hydrationResult.hydratedMessages.count),
                        "localMessages": .count(messages.count),
                        "selectedMessages": .count(hydrationResult.selectedCount),
                        "status": .status(.complete)
                    ]
                )
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.initialBounded",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - hydrateStart,
                    metadata: [
                        "localMessages": .count(messages.count),
                        "status": .status(.failed)
                    ]
                )
                throw error
            }
            applyOpenCodeHydrationResult(hydrationResult, project: project)
            // Advance anchors only after merge so a crash mid-apply cannot skip durable recovery.
            project.updateOpenCodeHydrationState(hydrationResult.storedState)

            reconcileOpenCodeSessionState(sessionState, project: project)
            project.updateLastModified()
            ChatRecoveryTiming.measure(
                runtime: CodingAgentRuntimeKind.openCode.rawValue,
                projectID: project.id.uuidString,
                operation: "opencode.finalSave",
                metadata: ["localMessages": .count(messages.count)]
            ) {
                saveChanges()
            }
            scheduleOpenCodeFullHydrationIfNeeded(initialResult: hydrationResult, project: project)
        } catch {
            print("📝 OpenCode hydration failed: \(error)")
            showActiveSessionIndicator = false
        }
    }

    func scheduleOpenCodeFullHydrationIfNeeded(
        initialResult: OpenCodeHydrationResult,
        project: RemoteProject
    ) {
        guard case .initialBounded(let limit) = initialResult.mode,
              initialResult.fetchedCount >= limit else { return }

        openCodeFullHydrationTask?.cancel()
        let ownedProjectID = project.id
        let generation = openCodeHydrationGeneration
        openCodeFullHydrationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            guard self.ownsOpenCodeWork(projectID: ownedProjectID, generation: generation, kind: .hydration),
                  self.modelContext != nil else { return }
            do {
                let runtime = self.runtimeRegistry.runtime(for: .openCode)
                let hydrateStart = DispatchTime.now().uptimeNanoseconds
                let result = try await runtime.hydrateMessages(for: project, mode: .fullRefresh)
                guard !Task.isCancelled else { return }
                guard self.ownsOpenCodeWork(projectID: ownedProjectID, generation: generation, kind: .hydration) else { return }
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.\(result.mode.timingName)",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - hydrateStart,
                    metadata: [
                        "fetchedMessages": .count(result.fetchedCount),
                        "hydratedMessages": .count(result.hydratedMessages.count),
                        "localMessages": .count(self.messages.count),
                        "selectedMessages": .count(result.selectedCount),
                        "status": .status(.complete)
                    ]
                )
                self.applyOpenCodeHydrationResult(result, project: project)
                project.updateOpenCodeHydrationState(result.storedState)
                self.prefetchCodeAgentsUIMedia(in: project, messages: self.messages)
                project.updateLastModified()
                self.saveChanges()
            } catch is CancellationError {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.fullRefresh",
                    elapsedNanoseconds: 0,
                    metadata: ["status": .status(.cancelled)]
                )
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: project.id.uuidString,
                    operation: "opencode.hydrateMessages.fullRefresh",
                    elapsedNanoseconds: 0,
                    metadata: [
                        "localMessages": .count(self.messages.count),
                        "status": .status(.failed)
                    ]
                )
            }
        }
    }

    func applyOpenCodeHydrationResult(_ result: OpenCodeHydrationResult, project: RemoteProject) {
        var existingRuntimeMessageIDs = openCodeRuntimeMessageIDs(in: messages)
        var skippedDuplicateMessages = 0
        var skippedLocalUserMessages = 0
        var insertedMessages = 0
        var updatedMessages = 0
        let existingRuntimeMessageCount = existingRuntimeMessageIDs.count
        let dedupeStart = DispatchTime.now().uptimeNanoseconds
        for hydrated in result.hydratedMessages {
            let mergeAction = OpenCodeHydratedMessageMerge.action(
                for: hydrated,
                existingRuntimeMessageIDs: existingRuntimeMessageIDs,
                hasLocalUserMessage: hasLocalUserMessage(matching: hydrated.text)
            )
            switch mergeAction {
            case .updateExisting:
                if let existingMessage = messages.first(where: { openCodeRuntimeMessageID(from: $0) == hydrated.runtimeMessageID }) {
                    updateOpenCodeMessage(existingMessage, with: hydrated)
                    updatedMessages += 1
                } else {
                    skippedDuplicateMessages += 1
                }
                continue
            case .skipLocalUserDuplicate:
                skippedLocalUserMessages += 1
                continue
            case .insert:
                break
            }

            let message = createMessage(content: hydrated.text, role: hydrated.role, timestamp: hydrated.createdAt)
            if let originalPayload = hydrated.originalPayload {
                updateMessageWithJSON(message, content: hydrated.text, originalJSON: originalPayload, replaceOriginalJSON: true)
            }
            message.isComplete = hydrated.isComplete
            message.isStreaming = !hydrated.isComplete
            message.openCodeRuntimeFinalized = hydrated.isComplete
            existingRuntimeMessageIDs.insert(hydrated.runtimeMessageID)
            insertedMessages += 1
        }
        ChatRecoveryTiming.log(
            runtime: CodingAgentRuntimeKind.openCode.rawValue,
            projectID: project.id.uuidString,
            operation: "opencode.hydration.dedupeInsert.\(result.mode.timingName)",
            elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - dedupeStart,
            metadata: [
                "existingRuntimeMessages": .count(existingRuntimeMessageCount),
                "finalLocalMessages": .count(messages.count),
                "hydratedMessages": .count(result.hydratedMessages.count),
                "insertedMessages": .count(insertedMessages),
                "localMessages": .count(messages.count - insertedMessages),
                "skippedDuplicateMessages": .count(skippedDuplicateMessages),
                "skippedLocalUserMessages": .count(skippedLocalUserMessages),
                "updatedMessages": .count(updatedMessages),
                "status": .status(.complete)
            ]
        )
        noteOpenCodeHydrationApplied()
    }

    func timingStatus(for sessionStatus: CodingAgentRuntimeSessionState.Status) -> ChatRecoveryTiming.Status {
        switch sessionStatus {
        case .idle:
            return .inactive
        case .busy, .retrying:
            return .active
        case .unknown:
            return .unknown
        }
    }

    func reconcileOpenCodeSessionState(_ state: CodingAgentRuntimeSessionState, project: RemoteProject) {
        switch state.status {
        case .busy, .retrying:
            showActiveSessionIndicator = true
            isProcessing = true
            if let assistant = messages.last(where: { $0.role == .assistant }) {
                assistant.isStreaming = true
                assistant.isComplete = false
                streamingMessage = assistant
                streamingRedrawToken = UUID()
                project.activeStreamingMessageId = assistant.id
            }
        case .idle, .unknown:
            showActiveSessionIndicator = false
            isProcessing = false
            streamingMessage = nil
            streamingBlocks = []
            for message in messages where message.isStreaming {
                // REST message metadata is the finality authority for persisted
                // OpenCode rows. The status sample was taken before hydration and may
                // already be stale if a new async prompt started in between.
                if OpenCodePersistedMessageMetadata.runtimeMessageID(from: message) != nil {
                    continue
                }
                message.isStreaming = false
                message.isComplete = true
            }
            project.activeStreamingMessageId = nil
        }
    }

    func openCodeRuntimeMessageIDs(in messages: [Message]) -> Set<String> {
        Set(messages.compactMap(openCodeRuntimeMessageID(from:)))
    }

    func openCodeRuntimeMessageID(from message: Message) -> String? {
        OpenCodePersistedMessageMetadata.runtimeMessageID(from: message)
    }

    func hasLocalUserMessage(matching text: String) -> Bool {
        let remoteCore = OpenCodeChatMapper.normalizedUserPromptForDedupe(text)
        guard !remoteCore.isEmpty else {
            // Fully synthetic remote user turns should never insert.
            return true
        }
        return messages.contains { message in
            guard message.role == .user else { return false }
            let localCore = OpenCodeChatMapper.normalizedUserPromptForDedupe(message.content)
            if localCore.isEmpty { return false }
            if localCore == remoteCore { return true }
            // Local optimistic prompt vs OpenCode echo with extra whitespace / casing.
            if localCore.caseInsensitiveCompare(remoteCore) == .orderedSame { return true }
            return false
        }
    }

    func removeTransientOpenCodeMessage(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }

        let removedMessageID = message.id
        messages.remove(at: index)
        if streamingMessage?.id == removedMessageID {
            streamingMessage = nil
            streamingBlocks = []
        }
        messagesRevision += 1

        if let modelContext {
            modelContext.delete(message)
            saveChanges()
        }
    }
}
