import Foundation
import UserNotifications
import XCTest
@testable import CodeAgentsMobile

final class PushPayloadTests: XCTestCase {
    func testInteractiveGatewayPayloadEncodesSourceExclusionAndCompletionIdentity() throws {
        let payload = TriggerReplyFinishedPayload(
            cwd: "/srv/agent",
            conversationId: "ses_current00001",
            messagePreview: "Done",
            legacyRenderableAssistantCount: 7,
            assistantMessageCursor: 4,
            includePreview: true,
            excludeInstallationId: "install-123",
            excludeFCMToken: "fcm-token-123",
            completionId: "completion-456"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertEqual(object["exclude_installation_id"] as? String, "install-123")
        XCTAssertEqual(object["exclude_fcm_token"] as? String, "fcm-token-123")
        XCTAssertEqual(object["completion_id"] as? String, "completion-456")
        XCTAssertEqual(object["renderable_assistant_count"] as? Int, 7)
        XCTAssertEqual(object["assistant_message_cursor"] as? Int, 4)
        XCTAssertEqual(object["cursor_version"] as? Int, OpenCodeUnreadCursorSchema.currentVersion)
    }

    func testLegacyGatewayPayloadOmitsNewOptionalFields() throws {
        let payload = TriggerReplyFinishedPayload(
            cwd: "/srv/agent",
            conversationId: nil,
            messagePreview: nil,
            legacyRenderableAssistantCount: 9
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertNil(object["exclude_installation_id"])
        XCTAssertNil(object["exclude_fcm_token"])
        XCTAssertNil(object["completion_id"])
        XCTAssertEqual(object["renderable_assistant_count"] as? Int, 9)
        XCTAssertNil(object["assistant_message_cursor"])
        XCTAssertNil(object["cursor_version"])
    }

    func testCountOnlyLegacyPushCannotMutateUnreadCursor() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: [
            "type": "reply_finished",
            "server_key": "server-key",
            "cwd": "/srv/agent",
            "renderable_assistant_count": "4",
            "cursor_version": "2",
        ]))

        XCTAssertNil(payload.conversationId)
        XCTAssertEqual(payload.legacyRenderableAssistantCount, 4)
        XCTAssertNil(payload.renderableAssistantCount)
        XCTAssertNil(payload.cursorVersion)
        XCTAssertNil(
            ReplyFinishedSessionPolicy.cursorSessionId(
                incomingSessionId: payload.conversationId,
                incomingAssistantCount: payload.renderableAssistantCount
            )
        )
    }

    func testDistinctV2CursorDrivesUnreadState() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: [
            "type": "reply_finished",
            "server_key": "server-key",
            "cwd": "/srv/agent",
            "conversation_id": "ses_current00001",
            "renderable_assistant_count": "11",
            "assistant_message_cursor": "4",
            "cursor_version": "2",
        ]))

        XCTAssertEqual(payload.legacyRenderableAssistantCount, 11)
        XCTAssertEqual(payload.renderableAssistantCount, 4)
        XCTAssertEqual(payload.cursorVersion, 2)
    }

    func testLegacyConversationIdentifierCannotMutateOpenCodeCursor() throws {
        let payload = try XCTUnwrap(PushPayload(userInfo: [
            "type": "reply_finished",
            "server_key": "server-key",
            "cwd": "/srv/agent",
            "conversation_id": "legacy-conversation-id",
            "renderable_assistant_count": "4",
        ]))

        XCTAssertNil(
            ReplyFinishedSessionPolicy.cursorSessionId(
                incomingSessionId: payload.conversationId,
                incomingAssistantCount: payload.renderableAssistantCount
            )
        )
    }

    func testLocalPayloadRequiresMatchingAppGeneratedRequestIdentifier() throws {
        let projectID = UUID()
        let serverID = UUID()
        let userInfo: [AnyHashable: Any] = [
            "type": "reply_finished",
            "local": "1",
            "project_id": projectID.uuidString,
            "server_id": serverID.uuidString,
            "cwd": "/srv/agent",
            "conversation_id": "ses_current00001",
        ]

        XCTAssertNotNil(
            LocalReplyFinishedPayload(
                userInfo: userInfo,
                requestIdentifier: "reply-finished-\(projectID.uuidString)-completion"
            )
        )
        XCTAssertNil(
            LocalReplyFinishedPayload(
                userInfo: userInfo,
                requestIdentifier: "remote-fcm-request"
            )
        )
    }

    func testCompletionIdentityProducesStableDeliveryDedupeKey() throws {
        let userInfo: [AnyHashable: Any] = [
            "type": "reply_finished",
            "server_key": "server-key",
            "cwd": "/srv/agent",
            "completion_id": "completion-456",
        ]

        let first = try XCTUnwrap(PushPayload(userInfo: userInfo))
        let second = try XCTUnwrap(PushPayload(userInfo: userInfo))

        XCTAssertNotNil(first.deliveryDedupeKey)
        XCTAssertEqual(first.deliveryDedupeKey, second.deliveryDedupeKey)
    }

    func testCompletionPayloadSharesCanonicalAliasWithCursorOnlyFallback() throws {
        let cursorOnly = try XCTUnwrap(PushPayload(userInfo: [
            "type": "reply_finished",
            "server_key": "server-key",
            "cwd": "/srv/agent",
            "conversation_id": "ses_current00001",
            "assistant_message_cursor": "4",
            "cursor_version": "2",
        ]))
        let withCompletion = try XCTUnwrap(PushPayload(userInfo: [
            "type": "reply_finished",
            "server_key": "server-key",
            "cwd": "/srv/agent",
            "conversation_id": "ses_current00001",
            "assistant_message_cursor": "4",
            "cursor_version": "2",
            "completion_id": "completion-456",
        ]))

        XCTAssertFalse(Set(cursorOnly.deliveryDedupeKeys).isDisjoint(with: withCompletion.deliveryDedupeKeys))
    }
}

@MainActor
private final class BlockingReplyFinishedNotificationCenter: ReplyFinishedNotificationScheduling {
    private(set) var didBeginAdd = false
    private(set) var pendingIdentifiers: Set<String> = []
    private var addContinuation: CheckedContinuation<Void, Never>?

    func addReplyFinishedNotification(_ request: UNNotificationRequest) async throws {
        didBeginAdd = true
        await withCheckedContinuation { continuation in
            addContinuation = continuation
        }
        pendingIdentifiers.insert(request.identifier)
    }

    func removePendingReplyFinishedNotifications(withIdentifiers identifiers: [String]) {
        pendingIdentifiers.subtract(identifiers)
    }

    func removeDeliveredReplyFinishedNotifications(withIdentifiers identifiers: [String]) {
        _ = identifiers
    }

    func finishAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
}

extension PushPayloadTests {
    @MainActor
    func testDismissWhileNotificationAddIsSuspendedCannotProduceLateAlert() async throws {
        let center = BlockingReplyFinishedNotificationCenter()
        let suiteName = "PushPayloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = ReplyFinishedLocalNotificationCoordinator(center: center, defaults: defaults)
        let projectID = UUID()
        let request = UNNotificationRequest(
            identifier: "reply-finished-\(projectID.uuidString)-completion",
            content: UNMutableNotificationContent(),
            trigger: nil
        )

        let scheduling = Task { @MainActor in
            try await coordinator.replace(projectID: projectID, request: request) { true }
        }
        while !center.didBeginAdd {
            await Task.yield()
        }

        coordinator.dismiss(projectID: projectID)
        center.finishAdd()

        let didSchedule = try await scheduling.value
        XCTAssertFalse(didSchedule)
        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
    }

    @MainActor
    func testRelaunchedCoordinatorCanDismissPersistedCompletionIdentifier() async throws {
        let center = BlockingReplyFinishedNotificationCenter()
        let suiteName = "PushPayloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = UUID()
        let request = UNNotificationRequest(
            identifier: "reply-finished-\(projectID.uuidString)-completion",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
        let firstCoordinator = ReplyFinishedLocalNotificationCoordinator(
            center: center,
            defaults: defaults
        )
        let scheduling = Task { @MainActor in
            try await firstCoordinator.replace(projectID: projectID, request: request) { true }
        }
        while !center.didBeginAdd {
            await Task.yield()
        }
        center.finishAdd()
        let didSchedule = try await scheduling.value
        XCTAssertTrue(didSchedule)
        XCTAssertEqual(center.pendingIdentifiers, [request.identifier])

        let relaunchedCoordinator = ReplyFinishedLocalNotificationCoordinator(
            center: center,
            defaults: defaults
        )
        relaunchedCoordinator.dismiss(projectID: projectID)

        XCTAssertTrue(center.pendingIdentifiers.isEmpty)
    }
}
