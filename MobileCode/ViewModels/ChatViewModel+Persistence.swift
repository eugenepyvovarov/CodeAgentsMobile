//
//  ChatViewModel+Persistence.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel message load/save/create helpers
//

import SwiftUI
import Observation
import SwiftData

extension ChatViewModel {
    func isMessageBefore(_ lhs: Message, _ rhs: Message) -> Bool {
        switch (lhs.proxyEventId, rhs.proxyEventId) {
        case let (leftId?, rightId?):
            if leftId != rightId {
                return leftId < rightId
            }
            return lhs.timestamp < rhs.timestamp
        case (_?, nil), (nil, _?), (nil, nil):
            return lhs.timestamp < rhs.timestamp
        }
    }

    func insertionIndex(for message: Message) -> Int {
        for (index, existing) in messages.enumerated() {
            if isMessageBefore(message, existing) {
                return index
            }
        }
        return messages.count
    }


    /// Load messages for the current project
    func loadMessages() {
        guard let modelContext = modelContext,
              let projectId = projectId else { return }

        let timingStart = DispatchTime.now().uptimeNanoseconds
        var fetchedCount = 0
        var repairedStreamingCount = 0
        var restoredStreamingCount = 0
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: ProjectContext.shared.activeProject),
                projectID: projectId.uuidString,
                operation: "chat.loadMessages",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "fetchedMessages": .count(fetchedCount),
                    "localMessages": .count(messages.count),
                    "repairedStreamingMessages": .count(repairedStreamingCount),
                    "restoredStreamingMessages": .count(restoredStreamingCount),
                    "status": .status(timingStatus)
                ]
            )
        }
        
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.projectId == projectId
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        
        do {
            let fetched = try modelContext.fetch(descriptor)
            fetchedCount = fetched.count
            messages = fetched.sorted { isMessageBefore($0, $1) }

            // Clear any stale UI state first
            streamingMessage = nil
            streamingBlocks = []
            isProcessing = false
            isLoadingPreviousSession = false
            print("📝 loadMessages: Set isLoadingPreviousSession = false")
            
            // Check if the last assistant message was streaming when app closed
            if let lastMessage = messages.last,
               lastMessage.role == .assistant,
               lastMessage.isStreaming {
                
                // Check if the message actually completed (has a result message)
                let hasCompletedSession = lastMessage.isComplete
                
                if hasCompletedSession {
                    // Message completed successfully, just fix the streaming flag
                    lastMessage.isStreaming = false
                    lastMessage.isComplete = true
                    repairedStreamingCount += 1
                    if let project = ProjectContext.shared.activeProject,
                       project.activeStreamingMessageId == lastMessage.id {
                        project.activeStreamingMessageId = nil
                        project.updateLastModified()
                    }
                    saveChanges()
                } else {
                    // Message was truly interrupted - show streaming state
                    streamingMessage = lastMessage
                    isProcessing = true
                    streamingRedrawToken = UUID()
                    restoredStreamingCount += 1
                    
                    // Parse existing content to restore streaming blocks
                    if let structuredMessages = lastMessage.structuredMessages {
                        var blocks: [ContentBlock] = []
                        
                        for structured in structuredMessages {
                            if structured.type == "assistant",
                               let messageContent = structured.message {
                                // Extract content blocks from the assistant message
                                switch messageContent.content {
                                case .blocks(let contentBlocks):
                                    blocks.append(contentsOf: contentBlocks)
                                case .text(let text):
                                    blocks.append(.text(TextBlock(type: "text", text: text)))
                                }
                            }
                        }
                        
                        streamingBlocks = blocks
                    }
                }
            }
        } catch {
            timingStatus = .failed
            print("Failed to load messages: \(error)")
            messages = []
        }
    }

    
    /// Create and save a new message
    func createMessage(
        content: String,
        role: MessageRole,
        isComplete: Bool = true,
        isStreaming: Bool = false,
        proxyEventId: Int? = nil,
        timestamp: Date? = nil
    ) -> Message {
        let message = Message(content: content, role: role, projectId: projectId, originalJSON: nil, isComplete: isComplete, isStreaming: isStreaming)
        message.proxyEventId = proxyEventId

        if let timestamp {
            message.timestamp = timestamp
        } else if role == .assistant {
            // For assistant messages, add a small time offset to ensure they come after user messages
            message.timestamp = Date().addingTimeInterval(0.001) // 1 millisecond later
        }
        
        // Save the message
        saveMessage(message)

        if let project = ProjectContext.shared.activeProject,
           project.id == projectId {
            project.noteLastMessage(at: message.timestamp)
        }
        
        // Add to messages array in the correct position
        let insertIndex = insertionIndex(for: message)
        messages.insert(message, at: insertIndex)
        messagesRevision += 1
        
        return message
    }

    
    /// Update message content
    func updateMessage(_ message: Message, with content: String) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].content = content
            saveChanges()
            messagesRevision += 1
        }
    }

    
    /// Update message with content and original JSON
    func updateMessageWithJSON(
        _ message: Message,
        content: String,
        originalJSON: Data?,
        proxyEventId: Int? = nil,
        replaceOriginalJSON: Bool = false
    ) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            let existing = messages[index]
            let hadOriginalJSON = existing.originalJSON != nil
            existing.content = content
            if let originalJSON = originalJSON {
                let mergedJSON = replaceOriginalJSON
                    ? normalizedOriginalJSONLine(from: originalJSON)
                    : appendOriginalJSON(existing: existing.originalJSON, new: originalJSON)
                existing.originalJSON = mergedJSON
                ProxyStreamDiagnostics.log(
                    "message update id=\(message.id) contentLen=\(content.count) \(ProxyStreamDiagnostics.summarize(data: mergedJSON ?? originalJSON))"
                )
            }

            // The assistant placeholder is created immediately, but the real response can arrive later.
            // Stamp the first received proxy payload time onto the message so bubble timestamps reflect reality.
            if !hadOriginalJSON, existing.role == .assistant, existing.isStreaming {
                existing.timestamp = Date()
            }

            if let proxyEventId = proxyEventId, existing.proxyEventId != proxyEventId {
                existing.proxyEventId = proxyEventId
                // Avoid moving messages while the chat is visible; ExyteChat can mis-render after remove/insert moves.
                // We still persist the proxy event id for delta sync/deduping and rely on append-order stability.
            }
            if isProcessing || isLoadingPreviousSession {
                saveChangesThrottled()
            } else {
                saveChanges()
            }
            messagesRevision += 1
        }
    }

    func appendOriginalJSON(existing: Data?, new: Data) -> Data? {
        guard let newString = String(data: new, encoding: .utf8) else {
            return existing ?? new
        }
        let trimmedNew = newString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else {
            return existing ?? new
        }

        guard let existing = existing,
              let existingString = String(data: existing, encoding: .utf8),
              !existingString.isEmpty else {
            return trimmedNew.data(using: .utf8)
        }

        let existingLines = existingString
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if existingLines.contains(trimmedNew) {
            return existing
        }

        let separator = existingString.hasSuffix("\n") ? "" : "\n"
        let combined = existingString + separator + trimmedNew
        return combined.data(using: .utf8)
    }

    func normalizedOriginalJSONLine(from data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8) else {
            return data
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return data
        }
        return trimmed.data(using: .utf8)
    }

    
    /// Save any pending changes
    func saveChanges() {
        guard let modelContext = modelContext else { return }

        let timingStart = DispatchTime.now().uptimeNanoseconds
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: ProjectContext.shared.activeProject),
                projectID: projectId?.uuidString,
                operation: "chat.saveChanges",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "isLoadingPreviousSession": .flag(isLoadingPreviousSession),
                    "isProcessing": .flag(isProcessing),
                    "localMessages": .count(messages.count),
                    "status": .status(timingStatus)
                ]
            )
        }

        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        lastSaveTime = Date()
        
        do {
            try modelContext.save()
        } catch {
            timingStatus = .failed
            print("Failed to save: \(error)")
        }
    }

    
    /// Add an app error notice (orange banner UI — not an assistant reply).
    func addErrorMessage(_ text: String) {
        let message = createMessage(content: text, role: .assistant)
        message.isLocalError = true
        saveChanges()
        messagesRevision += 1
    }


    /// Save a message to persistence
    func saveMessage(_ message: Message) {
        guard let modelContext = modelContext else { return }

        modelContext.insert(message)
        if isProcessing || isLoadingPreviousSession {
            saveChangesThrottled()
        } else {
            saveChanges()
        }
    }


    /// Save any pending changes, coalescing rapid calls to avoid main-thread stalls.
    func saveChangesThrottled() {
        guard modelContext != nil else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastSaveTime)
        if elapsed >= saveThrottleInterval {
            saveChanges()
            return
        }

        guard pendingSaveTask == nil else { return }

        let delaySeconds = max(0, saveThrottleInterval - elapsed)
        let delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
        pendingSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            pendingSaveTask = nil
            saveChanges()
        }
    }
}
