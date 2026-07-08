import Foundation

/// Decides whether OpenCode remote recovery must run on the chat-open critical path.
/// Idle reopens with local SwiftData history stay local-first and hydrate in the background.
enum OpenCodeChatOpenPolicy {
    enum Decision: Equatable {
        /// Local messages are enough for first paint; remote hydrate can wait.
        case idleLocalFirst
        /// No local history yet — need remote hydrate before the thread looks complete.
        case remoteHydrationRequired
        /// Active/interrupted stream — need remote recovery on the critical path.
        case activeStreamRecovery
    }

    /// Whether chat open should await OpenCode session/hydrate before scheduling deferred work.
    static func blocksChatOpen(for decision: Decision) -> Bool {
        switch decision {
        case .idleLocalFirst:
            return false
        case .remoteHydrationRequired, .activeStreamRecovery:
            return true
        }
    }

    static func decision(
        hasOpenCodeSession: Bool,
        localMessageCount: Int,
        activeStreamingMessageId: UUID?,
        messages: [Message]
    ) -> Decision {
        guard hasOpenCodeSession else {
            return .idleLocalFirst
        }

        if let activeStreamingMessageId {
            if let active = messages.first(where: { $0.id == activeStreamingMessageId }) {
                if active.isComplete || !active.isStreaming {
                    // Stale marker with local history: paint locally and refresh in background.
                    return localMessageCount > 0 ? .idleLocalFirst : .remoteHydrationRequired
                }
                return .activeStreamRecovery
            }
            // Marker without matching message — recover remotely.
            return .activeStreamRecovery
        }

        if messages.contains(where: { $0.role == .assistant && $0.isStreaming && !$0.isComplete }) {
            return .activeStreamRecovery
        }

        if localMessageCount > 0 {
            return .idleLocalFirst
        }
        return .remoteHydrationRequired
    }
}
