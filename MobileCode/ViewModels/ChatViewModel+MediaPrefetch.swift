//
//  ChatViewModel+MediaPrefetch.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel CodeAgents UI media prefetch
//

import SwiftUI
import Observation
import SwiftData

extension ChatViewModel {
    func prefetchCodeAgentsUIMedia(in project: RemoteProject, messages: [Message]) {
        let request = ChatDeferredMediaPrefetchRequest(
            projectID: project.id,
            messages: messages.map { ChatMediaPrefetchMessageSnapshot(message: $0) }
        )
        prefetchCodeAgentsUIMedia(in: project, request: request)
    }

    func prefetchCodeAgentsUIMedia(in project: RemoteProject, request: ChatDeferredMediaPrefetchRequest) {
        let timingStart = DispatchTime.now().uptimeNanoseconds
        var mediaCandidateCount = 0
        var startedTaskCount = 0
        var skippedExistingTaskCount = 0
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "chat.prefetchCodeAgentsUIMedia",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "inputMessages": .count(request.messages.count),
                    "mediaCandidates": .count(mediaCandidateCount),
                    "skippedExistingTasks": .count(skippedExistingTaskCount),
                    "startedTasks": .count(startedTaskCount)
                ]
            )
        }

        guard request.projectID == project.id else { return }
        let sources = ChatMediaPrefetchPlanner.mediaSources(in: request.messages, projectID: request.projectID)

        mediaCandidateCount = sources.count

        for source in sources {
            let key = mediaPrefetchKey(for: source, projectID: request.projectID)
            guard mediaPrefetchTasks[key] == nil else {
                skippedExistingTaskCount += 1
                continue
            }
            let token = UUID()
            let task = Task { [weak self] in
                guard !Task.isCancelled else { return }
                _ = await ChatMediaLoader.shared.resolveMedia(source, project: project)
                await MainActor.run {
                    guard let self else { return }
                    let storedToken = self.mediaPrefetchTasks[key]?.token
                    guard ChatMediaPrefetchCompletionPolicy.shouldClearTask(
                        isCancelled: Task.isCancelled,
                        currentProjectID: self.projectId,
                        taskProjectID: request.projectID,
                        storedToken: storedToken,
                        taskToken: token
                    ) else { return }
                    self.mediaPrefetchTasks[key] = nil
                }
            }
            mediaPrefetchTasks[key] = MediaPrefetchTaskState(projectID: request.projectID, token: token, task: task)
            startedTaskCount += 1
        }
    }

    func mediaPrefetchKey(for source: CodeAgentsUIMediaSource, project: RemoteProject) -> String {
        mediaPrefetchKey(for: source, projectID: project.id)
    }

    func mediaPrefetchKey(for source: CodeAgentsUIMediaSource, projectID: UUID) -> String {
        ChatMediaPrefetchPlanner.sourceKey(for: source, projectID: projectID)
    }
}
