//
//  ChatViewModel+OpenCodeSend.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel OpenCode send/stream/abort
//

import SwiftUI
import Observation
import SwiftData
import UIKit

extension ChatViewModel {
    /// True while an OpenCode `/event` consumer is attached for this chat.
    var isOpenCodeEventStreamActive: Bool {
        guard let openCodeSendTask else { return false }
        return isProcessing && !openCodeSendTask.isCancelled
    }

    func abortCurrentResponse() async {
        guard let project = ProjectContext.shared.activeProject else { return }

        openCodeSendTask?.cancel()
        openCodeSendTask = nil
        // Invalidate generation so any lingering stream consumer exits without mutating UI.
        openCodeSendGeneration = UUID()
        clearAllOpenCodeReplyObservations()

        do {
            try await runtimeRegistry.runtime(for: .openCode).abort(project: project)
        } catch {
            addErrorMessage("Failed to stop OpenCode response: \(error.localizedDescription)")
        }

        finalizeOpenCodeStreamingMessages(markerForEmpty: "[Response stopped]")
        project.activeStreamingMessageId = nil
        project.updateLastModified()
        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
        showActiveSessionIndicator = false
        saveChanges()
    }

    
    /// Send a message to the active coding-agent runtime (OpenCode only).
    /// - Parameter text: The message text
    func sendMessage(_ text: String) async {
        await sendComposedMessage(text: text, attachments: [], skillName: nil, skillSlug: nil)
    }

    /// Optimistic chat send: save human text (+ local attachment previews) first, upload, then prompt OpenCode.
    func sendComposedMessage(
        text: String,
        attachments: [ChatComposerAttachment],
        skillName: String?,
        skillSlug: String?
    ) async {
        guard let project = ProjectContext.shared.activeProject else {
            addErrorMessage("No active agent. Please select an agent first.")
            return
        }

        // Promote legacy Claude projects before send so the OpenCode path is used.
        let migrationReport = await ClaudeToOpenCodeMigrationService.shared.migrateIfNeeded(
            project: project,
            modelContext: modelContext
        )
        if migrationReport.didMigrate || migrationReport.mcp.didImport {
            invalidateMCPCache()
            saveChanges()
        }

        let displayText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayText.isEmpty || !attachments.isEmpty else { return }

        var records = attachments.map(ChatMessageAttachment.fromComposer)

        // Promote staged files into Application Support so preview + retry survive temp purges.
        records = promoteLocalAttachmentsToDurableStore(records)

        // Insert the user bubble immediately (thumbnail + status), before any network work.
        let userMessage = createMessage(content: displayText, role: .user)
        if !records.isEmpty {
            userMessage.chatAttachments = records
            saveChanges()
            messagesRevision += 1
        }

        let uploadOutcome = await uploadPendingAttachments(
            on: userMessage,
            records: records,
            project: project
        )
        guard uploadOutcome.shouldContinue else { return }

        let wirePrompt = ChatSkillPromptBuilder.build(
            message: displayText,
            skillName: skillName,
            skillSlug: skillSlug,
            fileReferences: uploadOutcome.fileReferences
        )

        // Nothing to send (empty text and no files).
        if wirePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        await sendOpenCodeMessage(wirePrompt, project: project, createUserMessage: false)
    }

    /// Re-upload failed attachments from the on-device cache, then continue the OpenCode send.
    func retryFailedAttachments(on message: Message) async {
        guard let project = ProjectContext.shared.activeProject else {
            addErrorMessage("No active agent. Please select an agent first.")
            return
        }
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }

        var records = promoteLocalAttachmentsToDurableStore(messages[index].chatAttachments)
        let hasRetryable = records.contains {
            $0.uploadStatus == .failed && $0.remoteReference == nil && ChatAttachmentLocalStore.resolveExistingFile(at: $0.localPath) != nil
        }
        guard hasRetryable else {
            addErrorMessage("Cached file is no longer available. Attach the photo again.")
            return
        }

        // Mark only failed rows as uploading so the spinner replaces Retry?.
        records = records.map { record in
            var updated = record
            if updated.uploadStatus == .failed, updated.remoteReference == nil {
                updated.uploadStatus = .uploading
                updated.errorMessage = nil
            }
            return updated
        }
        updateMessageAttachments(messages[index], records)

        let uploadOutcome = await uploadPendingAttachments(
            on: messages[index],
            records: records,
            project: project,
            announceFailure: true
        )
        guard uploadOutcome.shouldContinue else { return }

        let displayText = messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
        let wirePrompt = ChatSkillPromptBuilder.build(
            message: displayText,
            skillName: nil,
            skillSlug: nil,
            fileReferences: uploadOutcome.fileReferences
        )
        guard !wirePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        await sendOpenCodeMessage(wirePrompt, project: project, createUserMessage: false)
    }

    func updateMessageAttachments(_ message: Message, _ attachments: [ChatMessageAttachment]) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].chatAttachments = attachments
        saveChanges()
        messagesRevision += 1
    }

    // MARK: - Attachment upload helpers

    private struct AttachmentUploadOutcome {
        let fileReferences: [String]
        let shouldContinue: Bool
    }

    private func promoteLocalAttachmentsToDurableStore(
        _ records: [ChatMessageAttachment]
    ) -> [ChatMessageAttachment] {
        records.map { record in
            guard let path = record.localPath, !path.isEmpty else { return record }
            do {
                let durable = try ChatAttachmentLocalStore.ensureDurableCopy(
                    at: path,
                    displayName: record.displayName
                )
                var updated = record
                updated.localPath = durable.path
                return updated
            } catch {
                return record
            }
        }
    }

    private func uploadPendingAttachments(
        on message: Message,
        records: [ChatMessageAttachment],
        project: RemoteProject,
        announceFailure: Bool = true
    ) async -> AttachmentUploadOutcome {
        var records = records
        let needsUpload = records.contains { $0.remoteReference == nil }
        if !needsUpload {
            return AttachmentUploadOutcome(
                fileReferences: records.compactMap(\.remoteReference),
                shouldContinue: true
            )
        }

        records = records.map { record in
            var updated = record
            if updated.remoteReference == nil {
                updated.uploadStatus = .uploading
                updated.errorMessage = nil
            }
            return updated
        }
        updateMessageAttachments(message, records)

        // One SSH session + mkdir for the whole batch; files still upload one-by-one.
        let uploadContext: ChatAttachmentUploadContext
        do {
            uploadContext = try await ChatAttachmentUploadService.shared.prepareUploadContext(for: project)
        } catch {
            for index in records.indices where records[index].remoteReference == nil {
                records[index].uploadStatus = .failed
                records[index].errorMessage = error.localizedDescription
            }
            updateMessageAttachments(message, records)
            if announceFailure {
                addErrorMessage("Attachment upload failed: \(error.localizedDescription)")
            }
            return AttachmentUploadOutcome(
                fileReferences: records.compactMap(\.remoteReference),
                shouldContinue: false
            )
        }

        var lastError: Error?
        for index in records.indices {
            if let existing = records[index].remoteReference, !existing.isEmpty {
                records[index].uploadStatus = .uploaded
                records[index].errorMessage = nil
                continue
            }

            let displayName = records[index].displayName
            guard let localURL = ChatAttachmentLocalStore.resolveExistingFile(at: records[index].localPath) else {
                records[index].uploadStatus = .failed
                records[index].errorMessage = ChatAttachmentError.missingLocalFile(displayName).localizedDescription
                lastError = ChatAttachmentError.missingLocalFile(displayName)
                continue
            }
            records[index].localPath = localURL.path

            do {
                let reference = try await ChatAttachmentUploadService.shared.uploadLocalFile(
                    localURL: localURL,
                    displayName: displayName,
                    using: uploadContext
                )
                records[index].remoteReference = reference
                records[index].uploadStatus = .uploaded
                records[index].errorMessage = nil
            } catch {
                records[index].uploadStatus = .failed
                records[index].errorMessage = error.localizedDescription
                lastError = error
            }
            updateMessageAttachments(message, records)
        }

        let fileReferences = records.compactMap(\.remoteReference)
        let anyFailed = records.contains { $0.uploadStatus == .failed || $0.remoteReference == nil }
        if anyFailed {
            if announceFailure {
                let detail = lastError?.localizedDescription ?? "Upload incomplete"
                addErrorMessage("Attachment upload failed: \(detail)")
            }
            return AttachmentUploadOutcome(fileReferences: fileReferences, shouldContinue: false)
        }

        return AttachmentUploadOutcome(fileReferences: fileReferences, shouldContinue: true)
    }

    func sendOpenCodeMessage(_ text: String, project: RemoteProject, createUserMessage: Bool = true) async {
        // Reserve ownership synchronously before any await so concurrent sends cannot both attach.
        let ownedProjectID = project.id
        guard projectId == ownedProjectID else {
            addErrorMessage("Chat is no longer bound to this agent.")
            return
        }

        // Soft-steer: session already has a live `/event` consumer. OpenCode's loop will
        // pick up this new user prompt at the next step boundary — do not dual-attach.
        if OpenCodeMidAnswerSendPolicy.mode(isEventStreamActive: isOpenCodeEventStreamActive) == .softSteerPromptOnly {
            if createUserMessage {
                _ = createMessage(content: text, role: .user)
            }
            project.selectedAgentRuntime = .openCode
            project.updateLastModified()
            saveChanges()
            await softSteerOpenCodePrompt(text, project: project)
            return
        }

        // Reject a second concurrent full stream for the same chat.
        if isOpenCodeEventStreamActive {
            addErrorMessage("A response is already in progress. Stop it or wait before sending again.")
            return
        }

        let sendGeneration = UUID()
        openCodeSendGeneration = sendGeneration

        await ensureSendTimeSetup(for: project, includeRules: false)
        guard ownsOpenCodeWork(projectID: ownedProjectID, generation: sendGeneration, kind: .send) else { return }

        if createUserMessage {
            _ = createMessage(content: text, role: .user)
        }

        project.selectedAgentRuntime = .openCode
        project.updateLastModified()
        saveChanges()
        guard ownsOpenCodeWork(projectID: ownedProjectID, generation: sendGeneration, kind: .send) else { return }

        clearStaleOpenCodeStreamingAnchor(on: project)

        let assistantMessage = createMessage(content: "", role: .assistant, isComplete: false, isStreaming: true)
        beginOpenCodeReplyObservation(generation: sendGeneration, initialMessageID: assistantMessage.id)
        streamingMessage = assistantMessage
        streamingRedrawToken = UUID()
        isProcessing = true
        project.activeStreamingMessageId = assistantMessage.id
        project.updateLastModified()
        saveChanges()

        // Strong self: the stream must outlive ChatView so leaving the chat still
        // finishes the reply, persists messages, and updates unread / notifications.
        // Background task: without this, iOS freezes the process when the user switches
        // apps and the reply never completes → no push.
        let backgroundTaskID = beginOpenCodeSendBackgroundExecution()
        let sendTask = Task { @MainActor in
            defer { self.endOpenCodeSendBackgroundExecution(backgroundTaskID) }
            await self.consumeOpenCodeSendStream(
                text: text,
                project: project,
                assistantMessage: assistantMessage,
                projectID: ownedProjectID,
                generation: sendGeneration
            )
        }
        openCodeSendTask = sendTask
        await sendTask.value
        if openCodeSendTask == sendTask {
            openCodeSendTask = nil
        }
    }

    /// Inject a follow-up while the agent is still answering (OpenCode prompt_async, no new /event).
    private func softSteerOpenCodePrompt(_ text: String, project: RemoteProject) async {
        isProcessing = true
        showActiveSessionIndicator = true
        do {
            let runtime = runtimeRegistry.runtime(for: .openCode)
            try await runtime.submitPrompt(text, in: project, messageId: nil, mcpServers: cachedMCPServers)
        } catch {
            addErrorMessage("Failed to send follow-up to OpenCode: \(error.localizedDescription)")
        }
    }

    private func clearStaleOpenCodeStreamingAnchor(on project: RemoteProject) {
        guard let existingId = project.activeStreamingMessageId else { return }
        let staleCutoff = Date().addingTimeInterval(-staleStreamingTimeout)
        let existingMessage = messages.first(where: { $0.id == existingId })
        let isStale = (existingMessage?.timestamp ?? project.lastModified) < staleCutoff

        if let existingMessage {
            if existingMessage.isComplete || !existingMessage.isStreaming || isStale {
                existingMessage.isStreaming = false
                existingMessage.isComplete = true
                project.activeStreamingMessageId = nil
                project.updateLastModified()
                saveChanges()
            }
        } else if isStale {
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        }
    }

    private func finalizeOpenCodeStreamingMessages(markerForEmpty: String?) {
        for message in messages where message.isStreaming {
            message.isStreaming = false
            message.isComplete = true
            if let markerForEmpty,
               message.role == .assistant,
               message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateMessage(message, with: markerForEmpty)
            }
        }
    }

    private func consumeOpenCodeSendStream(
        text: String,
        project: RemoteProject,
        assistantMessage: Message,
        projectID: UUID,
        generation: UUID
    ) async {
        var retainUnseenObservation = false
        do {
            let runtime = runtimeRegistry.runtime(for: .openCode)
            let stream = runtime.sendMessage(text, in: project, messageId: nil, mcpServers: cachedMCPServers)
            var didReceiveAnswerText = false
            var didReceiveProgress = false
            var toolMessagesByPartID: [String: Message] = [:]
            var textMessagesByPartID: [String: Message] = [:]
            var textMessagesByMessageID: [String: Message] = [:]
            var exactSubmittedReplyRuntimeIDs = Set<String>()
            var assistantMessageIsTransientProgress = false
            var assistantMessageWasRemoved = false
            // Placeholder may be removed; keep a live target for late progress/errors after soft-steer.
            var activeAssistantPlaceholder: Message? = assistantMessage

            for try await chunk in stream {
                if Task.isCancelled { break }
                guard ownsOpenCodeWork(projectID: projectID, generation: generation, kind: .send) else { break }

                let chunkType = chunk.metadata?["type"] as? String
                if chunk.metadata?["opencodeSubmittedReply"] as? Bool == true,
                   let runtimeMessageID = chunk.metadata?["opencodeMessageId"] as? String,
                   !runtimeMessageID.isEmpty {
                    exactSubmittedReplyRuntimeIDs.insert(runtimeMessageID)
                }

                if chunkType == "tool_permission" {
                    handleToolPermissionChunk(chunk, project: project)
                    continue
                }

                if chunkType == "opencode_question" {
                    didReceiveProgress = true
                    handleOpenCodeQuestionChunk(chunk, project: project)
                    continue
                }

                if chunkType == "opencode_tool" {
                    didReceiveProgress = true
                    let partID = chunk.metadata?["toolPartID"] as? String ?? UUID().uuidString
                    let toolMessage: Message
                    if let existing = toolMessagesByPartID[partID] {
                        toolMessage = existing
                    } else if let runtimeMessageID = chunk.metadata?["opencodeMessageId"] as? String,
                              let existing = messages.first(where: {
                                  openCodeRuntimeMessageID(from: $0) == runtimeMessageID
                                      && $0.role == .assistant
                              }) {
                        toolMessage = existing
                        toolMessagesByPartID[partID] = toolMessage
                    } else {
                        toolMessage = createMessage(
                            content: chunk.content,
                            role: .assistant,
                            isComplete: chunk.isComplete,
                            isStreaming: !chunk.isComplete
                        )
                        toolMessagesByPartID[partID] = toolMessage
                    }
                    registerOpenCodeReplyMessage(toolMessage, generation: generation)
                    project.activeStreamingMessageId = toolMessage.id
                    isProcessing = true

                    let originalJSON = (chunk.metadata?["originalJSON"] as? String)?.data(using: .utf8)
                    updateMessageWithJSON(
                        toolMessage,
                        content: chunk.content,
                        originalJSON: originalJSON,
                        replaceOriginalJSON: true
                    )
                    toolMessage.isStreaming = !chunk.isComplete
                    toolMessage.isComplete = chunk.isComplete

                    if let provider = chunk.metadata?["runtimeProvider"] as? String {
                        project.lastSuccessfulRuntimeProviderRawValue = provider
                    }
                    continue
                }

                if chunkType == "opencode_progress" {
                    didReceiveProgress = true
                    guard !didReceiveAnswerText else {
                        continue
                    }
                    let progressTarget = activeAssistantPlaceholder
                        ?? createMessage(content: "", role: .assistant, isComplete: false, isStreaming: true)
                    activeAssistantPlaceholder = progressTarget
                    registerOpenCodeReplyMessage(progressTarget, generation: generation)
                    updateMessage(progressTarget, with: chunk.content)
                    progressTarget.isStreaming = true
                    progressTarget.isComplete = false
                    assistantMessageIsTransientProgress = true
                    project.activeStreamingMessageId = progressTarget.id
                    isProcessing = true
                    if let provider = chunk.metadata?["runtimeProvider"] as? String {
                        project.lastSuccessfulRuntimeProviderRawValue = provider
                    }
                    continue
                }

                if chunk.isError {
                    let errorText = chunk.content.isEmpty ? "OpenCode failed to respond." : chunk.content
                    let lastTextMessage = textMessagesByMessageID.values.max(by: { $0.timestamp < $1.timestamp })
                    let errorTarget = activeAssistantPlaceholder
                        ?? lastTextMessage
                        ?? createMessage(content: "", role: .assistant, isComplete: false, isStreaming: true)
                    registerOpenCodeReplyMessage(errorTarget, generation: generation)
                    updateMessage(errorTarget, with: errorText)
                    errorTarget.isStreaming = false
                    errorTarget.isComplete = true
                    didReceiveAnswerText = true
                    break
                }

                if !chunk.content.isEmpty {
                    let messageID = chunk.metadata?["opencodeMessageId"] as? String
                    let partID = chunk.metadata?["opencodeCurrentPartId"] as? String
                    let targetMessage: Message
                    if let messageID, let existing = textMessagesByMessageID[messageID] {
                        targetMessage = existing
                    } else if let messageID,
                              let existing = messages.first(where: { openCodeRuntimeMessageID(from: $0) == messageID }) {
                        targetMessage = existing
                        textMessagesByMessageID[messageID] = existing
                    } else if let partID, let existing = textMessagesByPartID[partID] {
                        targetMessage = existing
                    } else if let placeholder = activeAssistantPlaceholder,
                              !didReceiveAnswerText,
                              !didReceiveProgress,
                              placeholder.content.isEmpty {
                        targetMessage = placeholder
                    } else {
                        targetMessage = createMessage(
                            content: "",
                            role: .assistant,
                            isComplete: false,
                            isStreaming: true
                        )
                    }
                    if let messageID {
                        textMessagesByMessageID[messageID] = targetMessage
                    }
                    if let partID {
                        textMessagesByPartID[partID] = targetMessage
                    }
                    registerOpenCodeReplyMessage(targetMessage, generation: generation)
                    updateOpenCodeMessage(targetMessage, with: chunk)
                    project.activeStreamingMessageId = targetMessage.id
                    isProcessing = true
                    didReceiveAnswerText = true
                    if let placeholder = activeAssistantPlaceholder,
                       targetMessage.id != placeholder.id,
                       assistantMessageIsTransientProgress || placeholder.content.isEmpty {
                        unregisterOpenCodeReplyMessage(placeholder, generation: generation)
                        removeTransientOpenCodeMessage(placeholder)
                        assistantMessageIsTransientProgress = false
                        assistantMessageWasRemoved = true
                        activeAssistantPlaceholder = nil
                    }
                }

                if let provider = chunk.metadata?["runtimeProvider"] as? String {
                    project.lastSuccessfulRuntimeProviderRawValue = provider
                }

                if chunk.isComplete {
                    if let partID = chunk.metadata?["opencodeCurrentPartId"] as? String,
                       let completedTextMessage = textMessagesByPartID[partID] {
                        completedTextMessage.isStreaming = false
                        completedTextMessage.isComplete = true
                    } else if let messageID = chunk.metadata?["opencodeMessageId"] as? String,
                              let completedTextMessage = textMessagesByMessageID[messageID] {
                        completedTextMessage.isStreaming = false
                        completedTextMessage.isComplete = true
                    } else if let placeholder = activeAssistantPlaceholder, !assistantMessageWasRemoved {
                        placeholder.isStreaming = false
                        placeholder.isComplete = true
                    }
                    // Do not break here: soft-steered follow-ups may continue on the same
                    // `/event` stream after a brief idle. Exit only when the runtime ends
                    // the stream (grace elapsed / SSE closed / error).
                }
            }

            guard ownsOpenCodeWork(projectID: projectID, generation: generation, kind: .send) else {
                return
            }

            if Task.isCancelled {
                finalizeOpenCodeStreamingMessages(markerForEmpty: nil)
            } else if !didReceiveAnswerText {
                let fallback = didReceiveProgress
                    ? "OpenCode ran steps but did not return a final message."
                    : "OpenCode finished without returning text."
                if let placeholder = activeAssistantPlaceholder, !assistantMessageWasRemoved {
                    updateMessage(placeholder, with: fallback)
                } else {
                    let fallbackMessage = createMessage(content: fallback, role: .assistant)
                    registerOpenCodeReplyMessage(fallbackMessage, generation: generation)
                }
            }

            for toolMessage in toolMessagesByPartID.values {
                toolMessage.isStreaming = false
                toolMessage.isComplete = true
            }
            for textMessage in textMessagesByPartID.values {
                textMessage.isStreaming = false
                textMessage.isComplete = true
            }
            if let placeholder = activeAssistantPlaceholder, !assistantMessageWasRemoved {
                placeholder.isStreaming = false
                placeholder.isComplete = true
            }
            project.activeStreamingMessageId = nil
            project.noteLastMessage()
            project.updateLastModified()
            saveChanges()

            // End stream-owned UI state before any notification I/O. The gateway can be
            // slow or unavailable and must never keep "still processing" visible or
            // route a new prompt into a stream that already ended.
            streamingMessage = nil
            streamingBlocks = []
            isProcessing = false
            showActiveSessionIndicator = false

            // When the user left this chat (agents list / other agent), bump unread and
            // fire the same reply_finished path scheduled jobs use.
            if !Task.isCancelled {
                guard let sessionID = OpenCodeSessionID.sanitize(project.openCodeSessionId) else {
                    clearOpenCodeReplyObservation(generation: generation)
                    return
                }
                let completedReplyRuntimeIDs = finalizedOpenCodeReplyRuntimeMessageIDs(
                    generation: generation,
                    sessionID: sessionID
                )
                let exactCompletedReplyRuntimeIDs = completedReplyRuntimeIDs.intersection(
                    exactSubmittedReplyRuntimeIDs
                )

                // Local fallback/errors are assistant-colored UI, not a completed
                // OpenCode reply. Never reopen unread or schedule a late notification
                // for old history when this send produced no finalized runtime message.
                if exactCompletedReplyRuntimeIDs.isEmpty {
                    clearOpenCodeReplyObservation(generation: generation)
                } else {
                    let canonicalSessionID = OpenCodeSessionID.sanitize(
                        project.openCodeCanonicalAssistantSessionId
                    )
                    let canonicalAssistantIDs = Set(project.openCodeCanonicalAssistantMessageIds)
                    guard canonicalSessionID == sessionID,
                          exactCompletedReplyRuntimeIDs.isSubset(of: canonicalAssistantIDs) else {
                        // Stream teardown performs an unbounded REST snapshot before
                        // returning. If that proof failed, do not label a bounded local
                        // count as an absolute cross-device cursor.
                        SSHLogger.log(
                            "Reply notification skipped: canonical assistant cursor unavailable",
                            level: .warning
                        )
                        clearOpenCodeReplyObservation(generation: generation)
                        return
                    }
                    let preview = messages
                        .filter {
                            UnreadBadgeMath.isFinalizedOpenCodeAssistant($0, sessionID: sessionID)
                                && exactCompletedReplyRuntimeIDs.contains(
                                    OpenCodePersistedMessageMetadata.runtimeMessageID(from: $0) ?? ""
                                )
                        }
                        .sorted { $0.timestamp < $1.timestamp }
                        .last(where: {
                            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        })?
                        .content
                    let absolute = canonicalAssistantIDs.count
                    let server = serverForCompletedReply(project)

                    // Give the final Exyte cell one render/layout pass. ChatDetailView uses
                    // the same small settle window before confirming that every changed
                    // reply row's tail was actually inside the visible chat viewport.
                    if UIApplication.shared.applicationState == .active {
                        try? await Task.sleep(nanoseconds: 75_000_000)
                    }
                    guard !Task.isCancelled else {
                        clearOpenCodeReplyObservation(generation: generation)
                        return
                    }
                    let wasFinalOutputSeen = wasFinalOpenCodeReplyOutputSeen(generation: generation)
                    if wasFinalOutputSeen {
                        clearOpenCodeReplyObservation(generation: generation)
                    } else {
                        // Keep unresolved per-row evidence until the user actually renders
                        // it (or leaves this project). Removing it on a timer would turn
                        // "not observed" into read eligibility as soon as the timer fired.
                        retainUnseenObservation = true
                        retainUnseenOpenCodeReplyObservation(generation: generation)
                    }

                    await PushNotificationsManager.shared.notifyInteractiveReplyFinished(
                        project: project,
                        server: server,
                        messagePreview: preview,
                        legacyRenderableAssistantCount: UnreadBadgeMath.renderableAssistantCount(in: messages),
                        absoluteAssistantCount: absolute,
                        wasFinalOutputSeen: wasFinalOutputSeen,
                        completionId: generation.uuidString
                    )
                    saveChanges()
                }
            }
        } catch is CancellationError {
            if ownsOpenCodeWork(projectID: projectID, generation: generation, kind: .send) {
                finalizeOpenCodeStreamingMessages(markerForEmpty: nil)
                project.activeStreamingMessageId = nil
                project.updateLastModified()
                saveChanges()
            }
        } catch {
            guard ownsOpenCodeWork(projectID: projectID, generation: generation, kind: .send) else {
                return
            }
            let errorText = "Failed to get OpenCode response: \(error.localizedDescription)"
            if assistantMessage.isStreaming || assistantMessage.content.isEmpty {
                updateMessage(assistantMessage, with: errorText)
                assistantMessage.isStreaming = false
                assistantMessage.isComplete = true
            } else {
                addErrorMessage(errorText)
            }
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        }

        if ownsOpenCodeWork(projectID: projectID, generation: generation, kind: .send) {
            streamingMessage = nil
            streamingBlocks = []
            isProcessing = false
            showActiveSessionIndicator = false
            if !retainUnseenObservation {
                clearOpenCodeReplyObservation(generation: generation)
            }
        }
    }

    private func serverForCompletedReply(_ project: RemoteProject) -> Server? {
        if let activeServer = ProjectContext.shared.activeServer,
           activeServer.id == project.serverId {
            return activeServer
        }
        if let loadedServer = ServerManager.shared.server(withId: project.serverId) {
            return loadedServer
        }
        guard let modelContext else { return nil }
        let serverID = project.serverId
        let descriptor = FetchDescriptor<Server>(
            predicate: #Predicate { server in server.id == serverID }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }
}
