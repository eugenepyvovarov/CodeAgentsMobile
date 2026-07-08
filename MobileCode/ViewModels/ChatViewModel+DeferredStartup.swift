//
//  ChatViewModel+DeferredStartup.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel post-ready deferred startup
//

import SwiftUI
import Observation
import SwiftData

extension ChatViewModel {
    func scheduleDeferredStartupAfterChatReady(projectID: UUID, runtimeKind: CodingAgentRuntimeKind) {
        let existingProjectID = deferredStartupProjectID
        cancelDeferredStartup(reason: "reschedule", projectID: existingProjectID)

        let messageSnapshot = messages.map { ChatMediaPrefetchMessageSnapshot(message: $0) }
        let mediaPrefetchRequest = ChatMediaPrefetchPlanner.postReadyRequest(
            projectID: projectID,
            messages: messageSnapshot
        )
        deferredStartupProjectID = projectID
        let startupToken = UUID()
        deferredStartupToken = startupToken
        ChatRecoveryTiming.log(
            runtime: runtimeKind.rawValue,
            projectID: projectID.uuidString,
            operation: "chat.deferredStartup.schedule",
            elapsedNanoseconds: 0,
            metadata: [
                "snapshotMessages": .count(messageSnapshot.count),
                "status": .status(.started)
            ]
        )

        deferredStartupTask = Task { @MainActor in
            let timingStart = DispatchTime.now().uptimeNanoseconds
            var timingStatus = ChatRecoveryTiming.Status.complete
            defer {
                ChatRecoveryTiming.log(
                    runtime: runtimeKind.rawValue,
                    projectID: projectID.uuidString,
                    operation: "chat.deferredStartup.run",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                    metadata: [
                        "snapshotMessages": .count(messageSnapshot.count),
                        "status": .status(timingStatus)
                    ]
                )
                if ChatDeferredStartupCompletionPolicy.shouldClearTask(
                    isCancelled: Task.isCancelled,
                    storedProjectID: self.deferredStartupProjectID,
                    taskProjectID: projectID,
                    storedToken: self.deferredStartupToken,
                    taskToken: startupToken
                ) {
                    self.deferredStartupTask = nil
                    self.deferredStartupProjectID = nil
                    self.deferredStartupToken = nil
                }
            }

            guard !Task.isCancelled else {
                timingStatus = .cancelled
                return
            }
            guard self.projectId == projectID,
                  let project = ProjectContext.shared.activeProject,
                  project.id == projectID else {
                timingStatus = .skipped
                return
            }

            // OpenCode-only deferred MCP refresh (Claude installation checks removed).
            _ = runtimeKind
            await self.refreshMCPServersAfterChatReadyIfNeeded(project: project)
            guard !Task.isCancelled else {
                timingStatus = .cancelled
                return
            }
            guard self.projectId == projectID else {
                timingStatus = .skipped
                return
            }

            self.prefetchCodeAgentsUIMedia(in: project, request: mediaPrefetchRequest)
        }
    }

    func cancelDeferredStartup(reason: String, projectID: UUID?) {
        let hadTask = deferredStartupTask != nil
        deferredStartupTask?.cancel()
        deferredStartupTask = nil
        deferredStartupProjectID = nil
        deferredStartupToken = nil

        let mediaTaskCount = mediaPrefetchTasks.count
        for state in mediaPrefetchTasks.values {
            state.task.cancel()
        }
        mediaPrefetchTasks.removeAll()

        guard hadTask || mediaTaskCount > 0 else { return }
        ChatRecoveryTiming.log(
            runtime: timingRuntimeName(for: ProjectContext.shared.activeProject),
            projectID: projectID?.uuidString,
            operation: "chat.deferredStartup.cancel",
            elapsedNanoseconds: 0,
            metadata: [
                "mediaTasks": .count(mediaTaskCount),
                "status": .status(.cancelled)
            ]
        )
        print("📝 Deferred startup cancelled (\(reason))")
    }
}
