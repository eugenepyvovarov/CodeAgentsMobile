import XCTest
@testable import CodeAgentsMobile

final class ProxyStreamErrorTests: XCTestCase {
    func testHttpErrorExposesStatusAndJSONPayloadFields() {
        let body = #"{"error":"conversation_unknown","message":"missing conversation","conversation_id":"abc"}"#
        let error = ProxyStreamError.httpError(status: 404, body: body)

        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.proxyErrorCode, "conversation_unknown")
        XCTAssertEqual(error.proxyErrorMessage, "missing conversation")
        XCTAssertNotNil(error.proxyErrorPayload)
    }

    func testProxyErrorPayloadNilForNonJSON() {
        let error = ProxyStreamError.httpError(status: 400, body: "not json")

        XCTAssertNil(error.proxyErrorPayload)
        XCTAssertNil(error.proxyErrorCode)
        XCTAssertNil(error.proxyErrorMessage)
    }

    func testInvalidResponseDescription() {
        let error = ProxyStreamError.invalidResponse("Missing canonical_id")
        XCTAssertTrue(error.localizedDescription.contains("Missing canonical_id"))
        XCTAssertNil(error.statusCode)
    }

    @MainActor
    func testStoredProxyConversationIdIsSanitizedForNormalRecoveryPath() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.proxyConversationId = "  stored-conversation  \n"

        XCTAssertEqual(project.sanitizedProxyConversationId, "stored-conversation")
    }

    @MainActor
    func testBlankStoredProxyConversationIdRequiresCanonicalFallback() {
        let project = RemoteProject(name: "repo", serverId: UUID())
        project.proxyConversationId = "  \n"

        XCTAssertNil(project.sanitizedProxyConversationId)
    }
}
