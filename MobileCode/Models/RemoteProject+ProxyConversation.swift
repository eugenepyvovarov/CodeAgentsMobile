//
//  RemoteProject+ProxyConversation.swift
//  CodeAgentsMobile
//

import Foundation

extension RemoteProject {
    /// Non-empty stored proxy/daemon conversation id, if present.
    var sanitizedProxyConversationId: String? {
        guard let conversationId = proxyConversationId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !conversationId.isEmpty else {
            return nil
        }
        return conversationId
    }

    /// Clears legacy Claude session + proxy conversation transport fields (local only).
    func clearLegacyClaudeTransportState() {
        claudeSessionId = nil
        proxyConversationId = nil
        proxyConversationGroupId = nil
        proxyLastEventId = nil
        updateLastModified()
    }
}
