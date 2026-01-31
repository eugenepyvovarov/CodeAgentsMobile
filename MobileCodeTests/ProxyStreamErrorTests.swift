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

    func testProxyErrorPayloadNilForNonJSON() {
        let error = ProxyStreamError.httpError(status: 400, body: "not json")

        XCTAssertNil(error.proxyErrorPayload)
        XCTAssertNil(error.proxyErrorCode)
        XCTAssertNil(error.proxyErrorMessage)
    }
}

