//
//  ChatViewModelSupport.swift
//  CodeAgentsMobile
//
//  Purpose: Pure helpers and planners used by ChatViewModel (no VM state).
//

import SwiftUI
import Observation
import SwiftData

// MARK: - Notifications
extension Notification.Name {
    static let mcpConfigurationChanged = Notification.Name("mcpConfigurationChanged")
    static let projectChatDidReset = Notification.Name("projectChatDidReset")
}

enum OpenCodeHydratedMessageMergeAction: Equatable {
    case insert
    case updateExisting
    case skipLocalUserDuplicate
}

enum OpenCodeHydratedMessageMerge {
    static func action(
        for hydrated: CodingAgentRuntimeHydratedMessage,
        existingRuntimeMessageIDs: Set<String>,
        hasLocalUserMessage: Bool
    ) -> OpenCodeHydratedMessageMergeAction {
        if existingRuntimeMessageIDs.contains(hydrated.runtimeMessageID) {
            return .updateExisting
        }
        if hydrated.role == .user, hasLocalUserMessage {
            return .skipLocalUserDuplicate
        }
        return .insert
    }
}

enum ChatMCPServerCachePolicy {
    static func needsFetch(
        cachedServerCount: Int,
        isInvalidated: Bool,
        lastFetchedAt: Date?,
        now: Date,
        staleInterval: TimeInterval
    ) -> Bool {
        if cachedServerCount == 0 || isInvalidated {
            return true
        }
        guard let lastFetchedAt else {
            return true
        }
        return now.timeIntervalSince(lastFetchedAt) >= staleInterval
    }
}

struct ChatMCPServerSetupPlan: Equatable {
    let shouldFetchMCPServers: Bool
    let shouldEnsureRules: Bool
}

enum ChatMCPServerSetupPlanner {
    /// - Parameter allowMCPFetch: When false, never fetch MCP on this path.
    ///   OpenCode send does not consume `mcpServers`; MCP refresh stays on post-ready /
    ///   explicit Abilities UI so the first message is not blocked on a status list.
    static func plan(
        cachedServerCount: Int,
        isInvalidated: Bool,
        lastFetchedAt: Date?,
        now: Date,
        staleInterval: TimeInterval,
        includeRules: Bool,
        allowMCPFetch: Bool = true
    ) -> ChatMCPServerSetupPlan {
        let shouldFetchMCPServers: Bool
        if allowMCPFetch {
            shouldFetchMCPServers = ChatMCPServerCachePolicy.needsFetch(
                cachedServerCount: cachedServerCount,
                isInvalidated: isInvalidated,
                lastFetchedAt: lastFetchedAt,
                now: now,
                staleInterval: staleInterval
            )
        } else {
            shouldFetchMCPServers = false
        }
        return ChatMCPServerSetupPlan(
            shouldFetchMCPServers: shouldFetchMCPServers,
            shouldEnsureRules: includeRules
        )
    }
}

struct ChatMediaPrefetchMessageSnapshot {
    let role: MessageRole
    let isComplete: Bool
    let content: String

    init(role: MessageRole, isComplete: Bool, content: String) {
        self.role = role
        self.isComplete = isComplete
        self.content = content
    }

    init(message: Message) {
        self.role = message.role
        self.isComplete = message.isComplete
        self.content = message.content
    }
}

struct ChatDeferredMediaPrefetchRequest {
    let projectID: UUID
    let messages: [ChatMediaPrefetchMessageSnapshot]
}

enum ChatMediaPrefetchPlanner {
    static let maxPrefetchSources = 40

    static func postReadyRequest(
        projectID: UUID,
        messages: [ChatMediaPrefetchMessageSnapshot]
    ) -> ChatDeferredMediaPrefetchRequest {
        ChatDeferredMediaPrefetchRequest(projectID: projectID, messages: messages)
    }

    static func mediaSources(
        in messages: [ChatMediaPrefetchMessageSnapshot],
        projectID: UUID
    ) -> [CodeAgentsUIMediaSource] {
        var seenKeys = Set<String>()
        seenKeys.reserveCapacity(32)
        var sources: [CodeAgentsUIMediaSource] = []
        sources.reserveCapacity(32)

        for message in messages {
            guard message.role == .assistant else { continue }
            guard message.isComplete else { continue }
            let content = message.content
            let lowercased = content.lowercased()
            guard lowercased.contains("codeagents_ui"), lowercased.contains("```") else { continue }

            let segments = CodeAgentsUIBlockExtractor.segments(from: content)
            for segment in segments {
                guard case .ui(let block) = segment else { continue }
                for element in block.elements {
                    appendSources(from: element, projectID: projectID, seenKeys: &seenKeys, sources: &sources)
                    if sources.count >= maxPrefetchSources {
                        break
                    }
                }

                if sources.count >= maxPrefetchSources {
                    break
                }
            }

            if sources.count >= maxPrefetchSources {
                break
            }
        }

        return sources
    }

    static func sourceKey(for source: CodeAgentsUIMediaSource, projectID: UUID) -> String {
        switch source {
        case .url(let url):
            return "url:\(url.absoluteString)"
        case .projectFile(let path):
            return "project:\(projectID.uuidString):\(path)"
        case .base64(let mediaType, let data):
            return "base64:\(mediaType):\(data.hashValue)"
        }
    }

    private static func appendSources(
        from element: CodeAgentsUIElement,
        projectID: UUID,
        seenKeys: inout Set<String>,
        sources: inout [CodeAgentsUIMediaSource]
    ) {
        switch element {
        case .image(let image):
            appendPrefetchSource(image.source, projectID: projectID, seenKeys: &seenKeys, sources: &sources)
        case .gallery(let gallery):
            for image in gallery.images {
                guard sources.count < maxPrefetchSources else { break }
                appendPrefetchSource(image.source, projectID: projectID, seenKeys: &seenKeys, sources: &sources)
            }
        case .video(let video):
            if let poster = video.poster {
                appendPrefetchSource(poster, projectID: projectID, seenKeys: &seenKeys, sources: &sources)
            }
        case .card(let card):
            for nested in card.content {
                guard sources.count < maxPrefetchSources else { break }
                appendSources(from: nested, projectID: projectID, seenKeys: &seenKeys, sources: &sources)
            }
        case .markdown, .table, .chart:
            break
        }
    }

    private static func appendPrefetchSource(
        _ source: CodeAgentsUIMediaSource,
        projectID: UUID,
        seenKeys: inout Set<String>,
        sources: inout [CodeAgentsUIMediaSource]
    ) {
        guard sources.count < maxPrefetchSources else { return }
        let key = sourceKey(for: source, projectID: projectID)
        guard !seenKeys.contains(key) else { return }
        seenKeys.insert(key)
        sources.append(source)
    }
}

enum ChatMediaPrefetchCompletionPolicy {
    static func shouldClearTask(
        isCancelled: Bool,
        currentProjectID: UUID?,
        taskProjectID: UUID,
        storedToken: UUID?,
        taskToken: UUID
    ) -> Bool {
        guard !isCancelled else { return false }
        guard currentProjectID == taskProjectID else { return false }
        return storedToken == taskToken
    }
}

enum ChatDeferredStartupCompletionPolicy {
    static func shouldClearTask(
        isCancelled: Bool,
        storedProjectID: UUID?,
        taskProjectID: UUID,
        storedToken: UUID?,
        taskToken: UUID
    ) -> Bool {
        guard !isCancelled else { return false }
        guard storedProjectID == taskProjectID else { return false }
        return storedToken == taskToken
    }
}

struct MediaPrefetchTaskState {
    let projectID: UUID
    let token: UUID
    let task: Task<Void, Never>
}
