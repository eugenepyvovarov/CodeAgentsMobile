//
//  ChatViewModel+ToolApproval.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel tool approval & OpenCode questions
//

import SwiftUI
import Observation
import SwiftData

extension ChatViewModel {
    func handleToolPermissionChunk(_ chunk: MessageChunk, project: RemoteProject) {
        guard let request = toolApprovalRequest(from: chunk, agentId: project.id) else { return }

        toolApprovalStore.recordKnownTool(request.toolName, agentId: project.id)

        guard !handledToolPermissionIds.contains(request.id) else { return }
        handledToolPermissionIds.insert(request.id)

        if let record = toolApprovalStore.decision(for: request.toolName, agentId: project.id) {
            Task { await sendToolApprovalDecision(request: request, decision: record.decision, scope: record.scope) }
            return
        }

        enqueueToolApproval(request, announce: true)
    }

    func handleOpenCodeQuestionChunk(_ chunk: MessageChunk, project: RemoteProject) {
        guard let request = openCodeQuestionRequest(from: chunk) else { return }
        guard !handledOpenCodeQuestionIds.contains(request.id) else { return }
        handledOpenCodeQuestionIds.insert(request.id)

        enqueueOpenCodeQuestion(
            PendingOpenCodeQuestionRequest(request: request, agentId: project.id),
            announce: true
        )
    }

    func respondToToolApproval(
        _ request: ToolApprovalRequest,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope
    ) {
        if scope != .once {
            toolApprovalStore.record(
                decision: decision,
                scope: scope,
                toolName: request.toolName,
                agentId: request.agentId
            )
        }

        activeToolApproval = nil
        dequeueNextToolApproval()

        Task { await sendToolApprovalDecision(request: request, decision: decision, scope: scope) }
    }

    func respondToToolApprovalAll(
        _ request: ToolApprovalRequest,
        decision: ToolApprovalDecision
    ) {
        toolApprovalStore.setAgentPolicy(decision, agentId: request.agentId)

        let pending = pendingToolApprovals
        pendingToolApprovals.removeAll { $0.agentId == request.agentId }
        activeToolApproval = nil
        dequeueNextToolApproval()

        Task { await sendToolApprovalDecision(request: request, decision: decision, scope: .agent) }
        for pendingRequest in pending where pendingRequest.agentId == request.agentId {
            Task { await sendToolApprovalDecision(request: pendingRequest, decision: decision, scope: .agent) }
        }
    }

    func respondToOpenCodeQuestion(
        _ pendingRequest: PendingOpenCodeQuestionRequest,
        answers: [[String]]
    ) {
        activeOpenCodeQuestion = nil
        dequeueNextOpenCodeQuestion()

        Task { await sendOpenCodeQuestionReply(pendingRequest: pendingRequest, answers: answers) }
    }

    func rejectOpenCodeQuestion(_ pendingRequest: PendingOpenCodeQuestionRequest) {
        activeOpenCodeQuestion = nil
        dequeueNextOpenCodeQuestion()

        Task { await sendOpenCodeQuestionReject(pendingRequest: pendingRequest) }
    }

    func sendToolApprovalDecision(
        request: ToolApprovalRequest,
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope = .once
    ) async {
        guard let project = ProjectContext.shared.activeProject,
              project.id == request.agentId else { return }

        let message = decision == .deny ? "Permission denied by user." : nil
        do {
            try await runtimeRegistry.runtime(for: .openCode).replyToPermission(
                project: project,
                permissionId: request.id,
                decision: decision,
                scope: scope,
                message: message
            )
        } catch {
            await MainActor.run {
                // OpenCode permission replies use OpenCodeClient errors, not the legacy proxy stream client.
                let message = error.localizedDescription.lowercased()
                if message.contains("permission") && (message.contains("not found") || message.contains("404") || message.contains("expired")) {
                    addErrorMessage(
                        "Tool approval expired (permission no longer active). Please retry the request."
                    )
                    return
                }

                addErrorMessage(
                    "Failed to send tool approval for \(request.toolName): \(error.localizedDescription)"
                )
                enqueueToolApproval(request, announce: false, atFront: true)
            }
        }
    }

    func toolApprovalRequest(from chunk: MessageChunk, agentId: UUID) -> ToolApprovalRequest? {
        guard let metadata = chunk.metadata else { return nil }
        let permissionId = metadata["permissionId"] as? String ?? metadata["permission_id"] as? String
        guard let permissionId, !permissionId.isEmpty else { return nil }

        let toolName = metadata["toolName"] as? String
            ?? metadata["tool_name"] as? String
            ?? "Tool"
        let input = metadata["input"] as? [String: Any] ?? [:]
        let suggestions = metadata["suggestions"] as? [String]
            ?? metadata["permission_suggestions"] as? [String]
            ?? []
        let blockedPath = metadata["blockedPath"] as? String ?? metadata["blocked_path"] as? String

        return ToolApprovalRequest(
            id: permissionId,
            toolName: toolName,
            input: input,
            suggestions: suggestions,
            blockedPath: blockedPath,
            agentId: agentId
        )
    }

    func openCodeQuestionRequest(from chunk: MessageChunk) -> OpenCodeQuestionRequest? {
        guard let metadata = chunk.metadata else { return nil }
        if let request = metadata["questionRequest"] as? OpenCodeQuestionRequest {
            return request.id.isEmpty || request.questions.isEmpty ? nil : request
        }

        guard let questionId = metadata["questionId"] as? String, !questionId.isEmpty else { return nil }
        let questionText = chunk.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !questionText.isEmpty else { return nil }
        return OpenCodeQuestionRequest(
            id: questionId,
            sessionID: metadata["opencodeSessionId"] as? String,
            questions: [
                OpenCodeQuestion(
                    header: "Question",
                    question: questionText,
                    options: [],
                    custom: true
                )
            ]
        )
    }

    func enqueueToolApproval(
        _ request: ToolApprovalRequest,
        announce: Bool,
        atFront: Bool = false
    ) {
        if activeToolApproval == nil {
            activeToolApproval = request
        } else if atFront {
            pendingToolApprovals.insert(request, at: 0)
        } else {
            pendingToolApprovals.append(request)
        }

        if announce {
            _ = createMessage(content: "Permission required to use \(request.toolName).", role: .assistant)
        }
    }

    func enqueueOpenCodeQuestion(
        _ pendingRequest: PendingOpenCodeQuestionRequest,
        announce: Bool,
        atFront: Bool = false
    ) {
        if activeOpenCodeQuestion == nil {
            activeOpenCodeQuestion = pendingRequest
        } else if atFront {
            pendingOpenCodeQuestions.insert(pendingRequest, at: 0)
        } else {
            pendingOpenCodeQuestions.append(pendingRequest)
        }

        if announce,
           let question = pendingRequest.request.questions.first?.question.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty {
            _ = createMessage(content: "Question required: \(question)", role: .assistant)
        }
    }

    func dequeueNextToolApproval() {
        guard activeToolApproval == nil, !pendingToolApprovals.isEmpty else { return }
        activeToolApproval = pendingToolApprovals.removeFirst()
    }

    func dequeueNextOpenCodeQuestion() {
        guard activeOpenCodeQuestion == nil, !pendingOpenCodeQuestions.isEmpty else { return }
        activeOpenCodeQuestion = pendingOpenCodeQuestions.removeFirst()
    }

    func sendOpenCodeQuestionReply(
        pendingRequest: PendingOpenCodeQuestionRequest,
        answers: [[String]]
    ) async {
        guard let project = ProjectContext.shared.activeProject,
              project.id == pendingRequest.agentId else { return }

        do {
            try await runtimeRegistry.runtime(for: .openCode).replyToQuestion(
                project: project,
                questionId: pendingRequest.request.id,
                answers: answers
            )
        } catch {
            await MainActor.run {
                addErrorMessage("Failed to answer OpenCode question: \(error.localizedDescription)")
                enqueueOpenCodeQuestion(pendingRequest, announce: false, atFront: true)
            }
        }
    }

    func sendOpenCodeQuestionReject(
        pendingRequest: PendingOpenCodeQuestionRequest
    ) async {
        guard let project = ProjectContext.shared.activeProject,
              project.id == pendingRequest.agentId else { return }

        do {
            try await runtimeRegistry.runtime(for: .openCode).rejectQuestion(
                project: project,
                questionId: pendingRequest.request.id
            )
        } catch {
            await MainActor.run {
                addErrorMessage("Failed to skip OpenCode question: \(error.localizedDescription)")
                enqueueOpenCodeQuestion(pendingRequest, announce: false, atFront: true)
            }
        }
    }
}
