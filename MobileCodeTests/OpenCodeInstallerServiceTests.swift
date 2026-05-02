import XCTest
@testable import CodeAgentsMobile

final class OpenCodeInstallerServiceTests: XCTestCase {
    func testStatusClassifiesAuthRequiredHTTPResponse() {
        let status = OpenCodeInstallerService.status(
            from: "binary=present\nservice=active\n",
            healthError: OpenCodeClientError.httpError(status: 401, body: "unauthorized")
        )

        XCTAssertEqual(status.state, .authRequired)
    }

    func testStatusClassifiesMissingBinaryAsNotInstalled() {
        let status = OpenCodeInstallerService.status(
            from: "binary=missing\nservice=inactive\n",
            healthError: OpenCodeClientError.invalidResponse("connection refused")
        )

        XCTAssertEqual(status.state, .notInstalled)
    }

    func testStatusClassifiesInactiveServiceAsNotRunning() {
        let status = OpenCodeInstallerService.status(
            from: "binary=present\nservice=failed\n",
            healthError: OpenCodeClientError.invalidResponse("connection refused")
        )

        XCTAssertEqual(status.state, .notRunning)
        XCTAssertTrue(status.message.contains("failed"))
    }

    func testStatusFallsBackToUnreachable() {
        let status = OpenCodeInstallerService.status(
            from: "binary=present\nservice=active\n",
            healthError: OpenCodeClientError.invalidResponse("connection refused")
        )

        XCTAssertEqual(status.state, .unreachable)
    }
}
