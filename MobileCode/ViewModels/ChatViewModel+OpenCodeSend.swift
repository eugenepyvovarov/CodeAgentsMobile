//
//  ChatViewModel+OpenCodeSend.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel OpenCode send/stream/abort
//

import SwiftUI
import Observation
import SwiftData

extension ChatViewModel {
    func abortCurrentResponse() async {
        guard let project = ProjectContext.shared.activeProject else { return }

        do {
            try await runtimeRegistry.runtime(for: .openCode).abort(project: project)
        } catch {
            addErrorMessage("Failed to stop OpenCode response: \(error.localizedDescription)")
        }

        if let activeMessageId = project.activeStreamingMessageId,
           let message = messages.first(where: { $0.id == activeMessageId }) {
            if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updateMessage(message, with: "[Response stopped]")
            }
            message.isStreaming = false
            message.isComplete = true
        }

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

        await sendOpenCodeMessage(text, project: project)
    }

    func sendOpenCodeMessage(_ text: String, project: RemoteProject) async {
        if let existingId = project.activeStreamingMessageId {
            let staleCutoff = Date().addingTimeInterval(-staleStreamingTimeout)
            let existingMessage = messages.first(where: { $0.id == existingId })
            let isStale = (existingMessage?.timestamp ?? project.lastModified) < staleCutoff

            if let existingMessage = existingMessage {
                if existingMessage.isComplete || !existingMessage.isStreaming || isStale {
                    existingMessage.isStreaming = false
                    existingMessage.isComplete = true
                    project.activeStreamingMessageId = nil
                    project.updateLastModified()
                    saveChanges()
                } else {
                    addErrorMessage("Previous message is still processing. Please wait for it to complete or clear the chat.")
                    return
                }
            } else if project.lastModified < staleCutoff {
                project.activeStreamingMessageId = nil
                project.updateLastModified()
                saveChanges()
            } else {
                addErrorMessage("Previous message is still processing. Please wait for it to complete or clear the chat.")
                return
            }
        }

        await ensureSendTimeSetup(for: project, includeRules: false)

        if let previousStreaming = messages.last(where: { $0.isStreaming }) {
            previousStreaming.isStreaming = false
            previousStreaming.isComplete = true
            if previousStreaming.content.isEmpty && previousStreaming.originalJSON == nil {
                updateMessage(previousStreaming, with: "[Response was interrupted by new message]")
            }
            saveChanges()
        }

        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
        saveChanges()

        _ = createMessage(content: text, role: .user)
        let assistantMessage = createMessage(content: "", role: .assistant, isComplete: false, isStreaming: true)
        streamingMessage = assistantMessage
        streamingRedrawToken = UUID()
        isProcessing = true

        project.selectedAgentRuntime = .openCode
        project.activeStreamingMessageId = assistantMessage.id
        project.updateLastModified()
        saveChanges()

        do {
            let runtime = runtimeRegistry.runtime(for: .openCode)
            let stream = runtime.sendMessage(text, in: project, messageId: assistantMessage.id, mcpServers: cachedMCPServers)
            var didReceiveAnswerText = false
            var didReceiveProgress = false
            var toolMessagesByPartID: [String: Message] = [:]
            var textMessagesByPartID: [String: Message] = [:]
            var textMessagesByMessageID: [String: Message] = [:]
            var assistantMessageIsTransientProgress = false
            var assistantMessageWasRemoved = false

            for try await chunk in stream {
                let chunkType = chunk.metadata?["type"] as? String

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
                    } else {
                        toolMessage = createMessage(
                            content: chunk.content,
                            role: .assistant,
                            isComplete: chunk.isComplete,
                            isStreaming: !chunk.isComplete
                        )
                        toolMessagesByPartID[partID] = toolMessage
                    }
                    project.activeStreamingMessageId = toolMessage.id

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
                    updateMessage(assistantMessage, with: chunk.content)
                    assistantMessage.isStreaming = true
                    assistantMessage.isComplete = false
                    assistantMessageIsTransientProgress = true
                    project.activeStreamingMessageId = assistantMessage.id
                    if let provider = chunk.metadata?["runtimeProvider"] as? String {
                        project.lastSuccessfulRuntimeProviderRawValue = provider
                    }
                    continue
                }

                if chunk.isError {
                    let errorText = chunk.content.isEmpty ? "OpenCode failed to respond." : chunk.content
                    updateMessage(assistantMessage, with: errorText)
                    assistantMessage.isStreaming = false
                    assistantMessage.isComplete = true
                    didReceiveAnswerText = true
                    break
                }

                if !chunk.content.isEmpty {
                    let messageID = chunk.metadata?["opencodeMessageId"] as? String
                    let partID = chunk.metadata?["opencodeCurrentPartId"] as? String
                    let targetMessage: Message
                    if let messageID, let existing = textMessagesByMessageID[messageID] {
                        targetMessage = existing
                    } else if let partID, let existing = textMessagesByPartID[partID] {
                        targetMessage = existing
                    } else if !didReceiveAnswerText && !didReceiveProgress && assistantMessage.content.isEmpty {
                        targetMessage = assistantMessage
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
                    updateOpenCodeMessage(targetMessage, with: chunk)
                    project.activeStreamingMessageId = targetMessage.id
                    didReceiveAnswerText = true
                    if targetMessage.id != assistantMessage.id,
                       assistantMessageIsTransientProgress || assistantMessage.content.isEmpty {
                        removeTransientOpenCodeMessage(assistantMessage)
                        assistantMessageIsTransientProgress = false
                        assistantMessageWasRemoved = true
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
                    } else if !assistantMessageWasRemoved {
                        assistantMessage.isStreaming = false
                        assistantMessage.isComplete = true
                    } else {
                        project.activeStreamingMessageId = nil
                    }
                    break
                }
            }

            if !didReceiveAnswerText {
                let fallback = didReceiveProgress
                    ? "OpenCode ran steps but did not return a final message."
                    : "OpenCode finished without returning text."
                updateMessage(assistantMessage, with: fallback)
            }

            for toolMessage in toolMessagesByPartID.values {
                toolMessage.isStreaming = false
                toolMessage.isComplete = true
            }
            for textMessage in textMessagesByPartID.values {
                textMessage.isStreaming = false
                textMessage.isComplete = true
            }
            if !assistantMessageWasRemoved {
                assistantMessage.isStreaming = false
                assistantMessage.isComplete = true
            }
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        } catch {
            let errorText = "Failed to get OpenCode response: \(error.localizedDescription)"
            updateMessage(assistantMessage, with: errorText)
            assistantMessage.isStreaming = false
            assistantMessage.isComplete = true
            project.activeStreamingMessageId = nil
            project.updateLastModified()
            saveChanges()
        }

        streamingMessage = nil
        streamingBlocks = []
        isProcessing = false
    }
}
