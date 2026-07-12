//
//  Project.swift
//  CodeAgentsMobile
//
//
//  Purpose: Data model for remote project representation
//

import Foundation
import SwiftData

/// Represents a project on a remote server
@Model
final class RemoteProject {
    var id = UUID()
    var name: String
    var displayName: String?
    var path: String
    var lastModified: Date
    var createdAt: Date

    /// Timestamp of the latest chat message (user or assistant) for this agent.
    /// Used to order the Agents list — not bumped by hydration anchors, unread, or other metadata.
    var lastMessageAt: Date?
    
    /// Server ID where this project exists
    var serverId: UUID
    
    // Session management
    var claudeSessionId: String?
    var hasActiveClaudeStream: Bool = false
    
    var terminalSessionId: String?
    var hasActiveTerminal: Bool = false
    
    var hasActiveFileOperation: Bool = false
    
    // Nohup tracking properties
    var lastOutputFilePosition: Int?
    var nohupProcessId: String?
    var outputFilePath: String?
    
    // Active streaming message tracking
    var activeStreamingMessageId: UUID?

    // Proxy SSE event tracking
    var proxyLastEventId: Int?

    // Proxy conversation identifier
    var proxyConversationId: String?

    // Proxy conversation group identifier
    var proxyConversationGroupId: String?

    // Proxy agent identifier (stable across app reinstalls, stored in <agent>/.codeagents/codeagents.json)
    var proxyAgentId: String?

    // Agent env vars sync status (proxy-only)
    var envVarsPendingSync: Bool = false
    var envVarsLastSyncedAt: Date?
    var envVarsLastSyncError: String?

    // Proxy version tracking for sync decisions
    var proxyVersion: String?
    var proxyStartedAt: String?

    // MARK: - Agent Runtime Tracking

    /// Raw runtime value (`CodingAgentRuntimeKind.rawValue`) selected for this project.
    /// Missing or unknown values intentionally fall back to Claude proxy for existing projects.
    var agentRuntimeRawValue: String?

    /// Runtime/provider marker recorded after the last successful chat result.
    /// This is separate from `lastSuccessfulClaudeProviderRawValue` so OpenCode can track its own provider/model.
    var lastSuccessfulRuntimeProviderRawValue: String?

    // MARK: - OpenCode Tracking

    var openCodeSessionId: String?
    var openCodeLastMessageIds: [String] = []
    var openCodeLastPartIds: [String] = []
    /// Encoded as `partId=digest` entries for content-change detection during hydration.
    var openCodeLastPartDigests: [String] = []

    // MARK: - Claude → OpenCode Migration

    /// Migration schema version applied for this project.
    /// `nil` means migration has never completed successfully.
    var openCodeMigrationVersion: Int?

    /// Last non-sensitive migration error (names/status only; never secrets).
    var openCodeMigrationLastError: String?

    // MARK: - Claude Provider Tracking

    /// Raw provider value (`ClaudeModelProvider.rawValue`) recorded after the last successful chat result.
    /// Used to detect when the user switches providers and requires a chat reset to continue.
    var lastSuccessfulClaudeProviderRawValue: String?

    // MARK: - Unread Tracking (per-device)

    /// Conversation identifier associated with unread cursors.
    /// Stored separately from transport state to avoid coupling unread tracking to proxy plumbing.
    var unreadConversationId: String?

    /// Latest absolute unread cursor learned from push and/or proxy headers.
    var lastKnownUnreadCursor: Int = 0

    /// Cursor value considered "read" (advanced when the user views the chat and scrolls to bottom).
    var lastReadUnreadCursor: Int = 0

    // MARK: - Avatar cache (remote identity is source of truth)

    /// `AgentAvatarKind.rawValue` last applied from remote identity.
    var avatarKindRawValue: String?
    /// Emoji string when kind is emoji.
    var avatarEmoji: String?
    /// Absolute local file URL path for cached image thumbnail (device only).
    var avatarLocalImagePath: String?
    /// Remote `updated_at` when cache was last applied.
    var avatarRemoteUpdatedAt: Date?

    var avatarKind: AgentAvatarKind {
        get {
            guard let avatarKindRawValue, let kind = AgentAvatarKind(rawValue: avatarKindRawValue) else {
                return .none
            }
            return kind
        }
        set { avatarKindRawValue = newValue.rawValue }
    }

    init(name: String, displayName: String? = nil, serverId: UUID, basePath: String = "/root/projects") {
        self.id = UUID()
        self.name = name
        self.displayName = displayName
        self.path = "\(basePath)/\(name)"
        self.serverId = serverId
        self.lastModified = Date()
        self.createdAt = Date()
        self.agentRuntimeRawValue = CodingAgentRuntimeKind.openCode.rawValue
        // New projects are created on OpenCode and do not need legacy migration.
        self.openCodeMigrationVersion = ClaudeToOpenCodeMigration.currentVersion
    }
    
    func updateLastModified() {
        lastModified = Date()
    }

    /// Move agents-list ordering forward when a chat message is known.
    /// Only advances; never rewinds if an older message is re-hydrated.
    func noteLastMessage(at date: Date = Date()) {
        if let current = lastMessageAt, current >= date {
            return
        }
        lastMessageAt = date
    }

    /// Sort key for the Agents list: last chat message, else creation time.
    var agentsListSortDate: Date {
        lastMessageAt ?? createdAt
    }

    var selectedAgentRuntime: CodingAgentRuntimeKind {
        get {
            guard let agentRuntimeRawValue,
                  let runtime = CodingAgentRuntimeKind(rawValue: agentRuntimeRawValue) else {
                // Missing/unknown runtime markers are treated as OpenCode after Claude→OpenCode migration.
                return .openCode
            }
            return runtime
        }
        set {
            agentRuntimeRawValue = newValue.rawValue
        }
    }

    /// Whether this project still needs the Claude → OpenCode migration pass.
    var needsOpenCodeMigration: Bool {
        guard openCodeMigrationVersion == nil else {
            return false
        }
        guard let rawValue = agentRuntimeRawValue else {
            // Legacy projects created before runtime markers existed.
            return true
        }
        if rawValue == CodingAgentRuntimeKind.claudeProxy.rawValue {
            return true
        }
        // Unknown historical values still get a one-time promote + MCP import.
        return CodingAgentRuntimeKind(rawValue: rawValue) == nil
    }

    var openCodeHydrationState: OpenCodeHydrationState {
        var digests: [String: String] = [:]
        for entry in openCodeLastPartDigests {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let partID = String(entry[..<separator])
            let digest = String(entry[entry.index(after: separator)...])
            if !partID.isEmpty, !digest.isEmpty {
                digests[partID] = digest
            }
        }
        return OpenCodeHydrationState(
            messageIDs: Set(openCodeLastMessageIds),
            partIDs: Set(openCodeLastPartIds),
            partDigests: digests
        )
    }

    func updateOpenCodeHydrationState(_ state: OpenCodeHydrationState) {
        openCodeLastMessageIds = state.messageIDs.sorted()
        openCodeLastPartIds = state.partIDs.sorted()
        openCodeLastPartDigests = state.partDigests
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        updateLastModified()
    }

    @discardableResult
    func applyOpenCodeSessionFromPush(_ sessionId: String?) -> Bool {
        guard let sessionId = OpenCodeSessionID.sanitize(sessionId) else {
            return false
        }

        guard openCodeSessionId != sessionId else {
            return false
        }

        openCodeSessionId = sessionId
        openCodeLastMessageIds = []
        openCodeLastPartIds = []
        openCodeLastPartDigests = []
        updateLastModified()
        return true
    }

    func resetOpenCodeRuntimeState() {
        openCodeSessionId = nil
        openCodeLastMessageIds = []
        openCodeLastPartIds = []
        openCodeLastPartDigests = []
        lastSuccessfulRuntimeProviderRawValue = nil
        updateLastModified()
    }

    /// Clears Claude proxy transport anchors used for SSE recovery.
    /// Does not remove `proxyAgentId` (identity/tasks) or unread cursors.
    func clearClaudeProxyTransportState(clearActiveStreamingMessage: Bool = true) {
        claudeSessionId = nil
        proxyConversationId = nil
        proxyConversationGroupId = nil
        proxyLastEventId = nil
        hasActiveClaudeStream = false
        if clearActiveStreamingMessage {
            activeStreamingMessageId = nil
        }
        updateLastModified()
    }

    var legacyClaudeRuntimeState: LegacyClaudeRuntimeState {
        LegacyClaudeRuntimeState(
            claudeSessionId: claudeSessionId,
            hasActiveClaudeStream: hasActiveClaudeStream,
            activeStreamingMessageId: activeStreamingMessageId,
            proxyLastEventId: proxyLastEventId,
            proxyConversationId: proxyConversationId,
            proxyConversationGroupId: proxyConversationGroupId,
            proxyAgentId: proxyAgentId,
            nohupProcessId: nohupProcessId,
            outputFilePath: outputFilePath,
            lastOutputFilePosition: lastOutputFilePosition
        )
    }

    var displayTitle: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return name
    }

    var unreadCount: Int {
        max(0, lastKnownUnreadCursor - lastReadUnreadCursor)
    }

    var unreadBadgeText: String? {
        let count = unreadCount
        guard count > 0 else { return nil }
        if count >= 100 {
            return "99+"
        }
        return "\(count)"
    }
}

struct LegacyClaudeRuntimeState: Equatable {
    let claudeSessionId: String?
    let hasActiveClaudeStream: Bool
    let activeStreamingMessageId: UUID?
    let proxyLastEventId: Int?
    let proxyConversationId: String?
    let proxyConversationGroupId: String?
    let proxyAgentId: String?
    let nohupProcessId: String?
    let outputFilePath: String?
    let lastOutputFilePosition: Int?
}
