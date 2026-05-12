import XCTest
@testable import CodeAgentsMobile

final class ProxyStreamErrorTests: XCTestCase {
    func testPermissionNotFoundDetectsProxyPayload() {
        let body = "{\"error\":\"permission_not_found\",\"permission_id\":\"abc\"}"
        let error = ProxyStreamError.httpError(status: 404, body: body)

        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.proxyErrorCode, "permission_not_found")
        XCTAssertTrue(error.isPermissionNotFound)
    }

    func testPermissionNotFoundFalseWhenStatusNot404() {
        let body = "{\"error\":\"permission_not_found\",\"permission_id\":\"abc\"}"
        let error = ProxyStreamError.httpError(status: 500, body: body)

        XCTAssertFalse(error.isPermissionNotFound)
    }

    func testConversationUnknownDetectsProxyPayload() {
        let body = "{\"error\":\"conversation_unknown\",\"conversation_id\":\"abc\"}"
        let error = ProxyStreamError.httpError(status: 404, body: body)

        XCTAssertTrue(error.isConversationUnknown)
        XCTAssertFalse(error.isConversationMismatch)
        XCTAssertTrue(error.isConversationRecoveryError)
    }

    func testConversationMismatchDetectsProxyPayload() {
        let cwdError = ProxyStreamError.httpError(
            status: 409,
            body: "{\"error\":\"conversation_cwd_mismatch\",\"conversation_id\":\"abc\"}"
        )
        let groupError = ProxyStreamError.httpError(
            status: 409,
            body: "{\"error\":\"conversation_group_mismatch\",\"conversation_id\":\"abc\"}"
        )

        XCTAssertTrue(cwdError.isConversationMismatch)
        XCTAssertTrue(cwdError.isConversationRecoveryError)
        XCTAssertTrue(groupError.isConversationMismatch)
        XCTAssertTrue(groupError.isConversationRecoveryError)
    }

    @MainActor
    func testStoredProxyConversationIdIsSanitizedForNormalRecoveryPath() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.proxyConversationId = "  stored-conversation  \n"

        XCTAssertEqual(ClaudeCodeService.sanitizedStoredProxyConversationId(for: project), "stored-conversation")
    }

    @MainActor
    func testBlankStoredProxyConversationIdRequiresCanonicalFallback() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.proxyConversationId = "  \n"

        XCTAssertNil(ClaudeCodeService.sanitizedStoredProxyConversationId(for: project))
    }

    func testProxyErrorPayloadNilForNonJSON() {
        let error = ProxyStreamError.httpError(status: 400, body: "not json")

        XCTAssertNil(error.proxyErrorPayload)
        XCTAssertNil(error.proxyErrorCode)
        XCTAssertNil(error.proxyErrorMessage)
    }
}
