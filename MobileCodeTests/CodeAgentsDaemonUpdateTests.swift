import XCTest
@testable import CodeAgentsMobile

final class CodeAgentsDaemonUpdateTests: XCTestCase {
    func testParseHealthzExtractsVersionAndStatus() {
        let raw = """
        {"status":"ok","version":"7ce9caf","started_at":"2026-07-09T07:43:31Z","opencode":{"healthy":true,"version":"1.17.15"}}
        """

        let snapshot = CodeAgentsDaemonProvisioning.parseHealthz(raw)

        XCTAssertEqual(snapshot?.status, "ok")
        XCTAssertEqual(snapshot?.version, "7ce9caf")
        XCTAssertEqual(snapshot?.startedAt, "2026-07-09T07:43:31Z")
        XCTAssertEqual(snapshot?.isHealthy, true)
    }

    func testParseHealthzRejectsEmptyOrInvalidPayload() {
        XCTAssertNil(CodeAgentsDaemonProvisioning.parseHealthz(""))
        XCTAssertNil(CodeAgentsDaemonProvisioning.parseHealthz("not-json"))
        XCTAssertNil(CodeAgentsDaemonProvisioning.parseHealthz("{}"))
    }

    func testVersionsMatchShortAndFullSHA() {
        XCTAssertTrue(
            CodeAgentsDaemonProvisioning.versionsMatch(
                installed: "7ce9caf",
                expected: "7ce9cafabc123def4567890"
            )
        )
        XCTAssertTrue(
            CodeAgentsDaemonProvisioning.versionsMatch(
                installed: "7CE9CAF",
                expected: "7ce9caf"
            )
        )
        XCTAssertTrue(
            CodeAgentsDaemonProvisioning.versionsMatch(
                installed: "7ce9cafabc123def4567890",
                expected: "7ce9caf"
            )
        )
        XCTAssertFalse(
            CodeAgentsDaemonProvisioning.versionsMatch(
                installed: "deadbee",
                expected: "7ce9caf"
            )
        )
        XCTAssertFalse(
            CodeAgentsDaemonProvisioning.versionsMatch(
                installed: "unknown",
                expected: "7ce9caf"
            )
        )
        XCTAssertFalse(
            CodeAgentsDaemonProvisioning.versionsMatch(
                installed: nil,
                expected: "7ce9caf"
            )
        )
    }

    func testParseRemoteHeadFromLsRemoteAndGitHubJSON() {
        let lsRemote = "7ce9cafabc123def4567890123456789abcdef01\tHEAD\n"
        XCTAssertEqual(
            CodeAgentsDaemonProvisioning.parseRemoteHead(lsRemote),
            "7ce9cafabc123def4567890123456789abcdef01"
        )

        let bare = "  7ce9caf  \n"
        XCTAssertEqual(CodeAgentsDaemonProvisioning.parseRemoteHead(bare), "7ce9caf")

        let api = """
        {"sha":"7ce9cafabc123def4567890123456789abcdef01","commit":{"message":"fix"}}
        """
        XCTAssertEqual(
            CodeAgentsDaemonProvisioning.parseRemoteHead(api),
            "7ce9cafabc123def4567890123456789abcdef01"
        )

        XCTAssertNil(CodeAgentsDaemonProvisioning.parseRemoteHead(""))
        XCTAssertNil(CodeAgentsDaemonProvisioning.parseRemoteHead("not-a-sha"))
    }

    func testInstallCommandUsesSudoWhenRequested() {
        let root = CodeAgentsDaemonProvisioning.installCommand(useSudo: false)
        let sudo = CodeAgentsDaemonProvisioning.installCommand(useSudo: true)

        XCTAssertTrue(root.contains("INSTALL_DIR=/opt/codeagents-daemon"))
        XCTAssertTrue(root.contains(CodeAgentsDaemonProvisioning.installScriptURL))
        XCTAssertTrue(root.contains(CodeAgentsDaemonProvisioning.pinnedInstallCommit))
        XCTAssertFalse(root.contains("/HEAD/install.sh"))
        XCTAssertFalse(root.contains("sudo -n env"))

        XCTAssertTrue(sudo.contains("sudo -n env"))
        XCTAssertTrue(sudo.contains("INSTALL_DIR=/opt/codeagents-daemon"))
        XCTAssertTrue(sudo.contains("INSTALL_CLAUDE_CLI=0"))
    }

    func testRemoteHeadProbeCommandUsesPinnedCommit() {
        let command = CodeAgentsDaemonProvisioning.remoteHeadProbeCommand()

        XCTAssertTrue(command.contains(CodeAgentsDaemonProvisioning.pinnedInstallCommit))
        XCTAssertEqual(
            CodeAgentsDaemonProvisioning.expectedDaemonVersion,
            CodeAgentsDaemonProvisioning.pinnedInstallCommit
        )
        XCTAssertFalse(command.contains("git ls-remote"))
    }

    func testNormalizeVersionDropsUnknown() {
        XCTAssertEqual(CodeAgentsDaemonProvisioning.normalizeVersion("  7ce9CAF "), "7ce9caf")
        XCTAssertNil(CodeAgentsDaemonProvisioning.normalizeVersion("unknown"))
        XCTAssertNil(CodeAgentsDaemonProvisioning.normalizeVersion("  "))
        XCTAssertNil(CodeAgentsDaemonProvisioning.normalizeVersion(nil))
    }
}
