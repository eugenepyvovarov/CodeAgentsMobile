import XCTest
@testable import CodeAgentsMobile

@MainActor
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

    func testTransientHealthFailureDetectsTimeoutAndReset() {
        XCTAssertTrue(
            OpenCodeInstallerService.isTransientHealthFailure(
                OpenCodeClientError.requestTimedOut(seconds: 30)
            )
        )
        XCTAssertTrue(
            OpenCodeInstallerService.isTransientHealthFailure(
                OpenCodeClientError.invalidResponse("connection reset by peer")
            )
        )
        XCTAssertTrue(
            OpenCodeInstallerService.isTransientHealthFailure(
                OpenCodeClientError.httpError(status: 503, body: "unavailable")
            )
        )
        XCTAssertFalse(
            OpenCodeInstallerService.isTransientHealthFailure(
                OpenCodeClientError.httpError(status: 401, body: "unauthorized")
            )
        )
        XCTAssertFalse(
            OpenCodeInstallerService.isTransientHealthFailure(
                OpenCodeClientError.decodingFailed("bad json")
            )
        )
    }

    func testInvalidateRuntimeStatusCacheIsSafe() {
        OpenCodeInstallerService.shared.invalidateRuntimeStatusCache(for: UUID())
        OpenCodeInstallerService.shared.invalidateRuntimeStatusCache()
    }

    func testHealthyCacheTTLIsLongEnoughForNotificationReopen() {
        // Soft opens after notification should reuse a recent healthy probe.
        XCTAssertGreaterThanOrEqual(OpenCodeInstallerService.shared.healthyCacheTTL, 120)
    }

    func testAvailableAndDaemonUnavailableDoNotBlockForegroundChat() {
        XCTAssertFalse(OpenCodeRuntimeSetupStatus.available(version: "1.0").blocksForegroundChat)
        XCTAssertFalse(
            OpenCodeRuntimeSetupStatus.daemonUnavailable(version: "1.0", reason: "down")
                .blocksForegroundChat
        )
        XCTAssertTrue(OpenCodeRuntimeSetupStatus.unreachable("blip").blocksForegroundChat)
        XCTAssertTrue(OpenCodeRuntimeSetupStatus.sshUnavailable("offline").blocksForegroundChat)
    }
}
