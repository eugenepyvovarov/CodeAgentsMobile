import Foundation

enum ProxyEventRecovery {
    enum ChatOpenDecision: Equatable {
        case idleNoRemoteWork
        case clearCompletedActiveMessage(UUID)
        case remoteRecovery(UUID)

        var performsRemoteRecovery: Bool {
            if case .remoteRecovery = self { return true }
            return false
        }

        var skipsProxyHistorySync: Bool {
            !performsRemoteRecovery
        }

        var skipsCanonicalConversationLookup: Bool {
            !performsRemoteRecovery
        }

        var shouldCheckPreviousProxySession: Bool {
            performsRemoteRecovery
        }

        var shouldResumeActiveStream: Bool {
            performsRemoteRecovery
        }

        var resumesActiveStreamMessageId: UUID? {
            if case .remoteRecovery(let messageId) = self { return messageId }
            return nil
        }
    }

    static func chatOpenDecision(
        activeStreamingMessageId: UUID?,
        activeMessage: Message?
    ) -> ChatOpenDecision {
        guard let messageId = activeStreamingMessageId else {
            return .idleNoRemoteWork
        }
        if let activeMessage, activeMessage.isComplete || !activeMessage.isStreaming {
            return .clearCompletedActiveMessage(messageId)
        }
        return .remoteRecovery(messageId)
    }

    static func usableAnchor(project: RemoteProject, messages: [Message]) -> Int? {
        let messageAnchor = messages.compactMap(\.proxyEventId).max()
        switch (project.proxyLastEventId, messageAnchor) {
        case let (stored?, message?):
            return max(stored, message)
        case let (stored?, nil):
            return stored
        case let (nil, message?):
            return message
        case (nil, nil):
            return nil
        }
    }

    static func shouldRepairFullReplay(hasLocalMessages: Bool, usableAnchor: Int?) -> Bool {
        hasLocalMessages && usableAnchor == nil
    }

    static func repairReplayStartEventId(hasLocalMessages: Bool, usableAnchor: Int?) -> Int? {
        shouldRepairFullReplay(hasLocalMessages: hasLocalMessages, usableAnchor: usableAnchor) ? 0 : nil
    }

    static func shouldDestructivelyResync(
        previousConversationId: String?,
        currentConversationId: String?,
        didInitiallyBindFromMissingConversation: Bool
    ) -> Bool {
        previousConversationId != nil &&
            previousConversationId != currentConversationId &&
            !didInitiallyBindFromMissingConversation
    }

    static func isDuplicateReplayEvent(_ event: ProxyStreamEvent, existingEventIds: Set<Int>) -> Bool {
        guard let eventId = event.eventId else { return false }
        return existingEventIds.contains(eventId)
    }

    @discardableResult
    static func advanceLastEventId(project: RemoteProject, to eventId: Int?) -> Bool {
        guard let eventId else { return false }
        guard project.proxyLastEventId.map({ eventId > $0 }) ?? true else { return false }
        project.proxyLastEventId = eventId
        return true
    }

    @discardableResult
    static func advanceLastEventId(project: RemoteProject, events: [ProxyStreamEvent]) -> Bool {
        guard let maxEventId = events.compactMap(\.eventId).max() else { return false }
        return advanceLastEventId(project: project, to: maxEventId)
    }
}
