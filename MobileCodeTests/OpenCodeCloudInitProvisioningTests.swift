import XCTest
@testable import CodeAgentsMobile

final class OpenCodeCloudInitProvisioningTests: XCTestCase {
    func testGeneratedCloudInitInstallsAndStartsOpenCodeServer() throws {
        let cloudInit = try XCTUnwrap(CloudInitTemplate.generate(
            with: ["ssh-ed25519 AAAAFixture test@example.com"],
            openCodeServerPassword: "fixture_password"
        ))

        XCTAssertTrue(cloudInit.contains("ssh-ed25519 AAAAFixture test@example.com"))
        XCTAssertTrue(
            cloudInit.contains(
                "curl --connect-timeout 20 --retry 3 --retry-delay 2 -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"
            )
        )
        XCTAssertTrue(cloudInit.contains("opencode serve --hostname 127.0.0.1 --port 4096"))
        XCTAssertTrue(cloudInit.contains("systemctl enable --now opencode"))
        XCTAssertTrue(cloudInit.contains("http://127.0.0.1:4096/global/health"))
        XCTAssertTrue(cloudInit.contains("OPENCODE_SERVER_PASSWORD=\"fixture_password\""))
        XCTAssertTrue(cloudInit.contains("vendor_data: {enabled: false}"))
        XCTAssertTrue(cloudInit.contains("package_update: false"))
        XCTAssertTrue(cloudInit.contains("package_upgrade: false"))
        XCTAssertTrue(cloudInit.contains("Acquire::ForceIPv4=true"))
        XCTAssertTrue(cloudInit.contains("timeout --kill-after=10 180 apt-get"))
        XCTAssertFalse(cloudInit.contains("package_upgrade: true"))
        XCTAssertFalse(cloudInit.contains("package_update: true"))
        XCTAssertFalse(cloudInit.contains("set -eux"))
        XCTAssertTrue(cloudInit.contains("Installing CodeAgents daemon..."))
        XCTAssertTrue(cloudInit.contains("timeout --kill-after=15 300 bash -lc"))
        XCTAssertTrue(cloudInit.contains("SERVICE_NAME=codeagents-daemon"))
        XCTAssertTrue(cloudInit.contains("INSTALL_DIR=/opt/codeagents-daemon"))
        XCTAssertTrue(cloudInit.contains("INSTALL_CLAUDE_CLI=0"))
        XCTAssertTrue(cloudInit.contains(CodeAgentsDaemonProvisioning.pinnedInstallCommit))
        XCTAssertFalse(cloudInit.contains("/HEAD/install.sh"))
        XCTAssertTrue(cloudInit.contains("http://127.0.0.1:8787/healthz"))
        XCTAssertTrue(cloudInit.contains("foreground OpenCode chat is still available"))
        XCTAssertTrue(cloudInit.contains("Ensuring 2G swapfile for OpenCode headroom..."))
        XCTAssertTrue(cloudInit.contains("/swapfile none swap sw 0 0"))
        XCTAssertTrue(cloudInit.contains("vm.swappiness=10"))
        XCTAssertTrue(cloudInit.contains("99-codeagents-keepalive.conf"))
        XCTAssertTrue(cloudInit.contains("ClientAliveInterval 30"))
        XCTAssertTrue(cloudInit.contains("ClientAliveCountMax 10"))
        XCTAssertFalse(cloudInit.contains("@anthropic-ai/claude-code"))
        XCTAssertFalse(cloudInit.contains("{{"))
    }

    func testOpenCodeEnvironmentFileCanOmitPassword() {
        let environment = OpenCodeServerProvisioning.environmentFile(password: nil)

        XCTAssertTrue(environment.contains("OPENCODE_SERVER_USERNAME=\"opencode\""))
        XCTAssertFalse(environment.contains("OPENCODE_SERVER_PASSWORD"))
    }

    func testManualInstallScriptCreatesServiceAndPasswordAuth() {
        let script = OpenCodeServerProvisioning.manualInstallScript(
            username: "mobile",
            password: "fixture_password"
        )

        XCTAssertTrue(script.contains("useradd -m -s /bin/bash codeagent"))
        XCTAssertTrue(
            script.contains(
                "curl --connect-timeout 20 --retry 3 --retry-delay 2 -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"
            )
        )
        XCTAssertTrue(script.contains("cat > /etc/opencode-server.env"))
        XCTAssertTrue(script.contains("OPENCODE_SERVER_USERNAME=\"mobile\""))
        XCTAssertTrue(script.contains("OPENCODE_SERVER_PASSWORD=\"fixture_password\""))
        XCTAssertTrue(script.contains("cat > /etc/systemd/system/opencode.service"))
        XCTAssertTrue(script.contains("systemctl enable --now opencode"))
        XCTAssertTrue(script.contains("http://127.0.0.1:4096/global/health"))
        XCTAssertTrue(script.contains("SERVICE_NAME=codeagents-daemon"))
        XCTAssertTrue(script.contains("INSTALL_DIR=/opt/codeagents-daemon"))
        XCTAssertTrue(script.contains("INSTALL_CLAUDE_CLI=0"))
        XCTAssertTrue(script.contains(CodeAgentsDaemonProvisioning.pinnedInstallCommit))
        XCTAssertFalse(script.contains("/HEAD/install.sh"))
        XCTAssertTrue(script.contains("http://127.0.0.1:8787/healthz"))
        XCTAssertTrue(script.contains("foreground OpenCode chat is still available"))
        XCTAssertTrue(script.contains("Ensuring 2G swapfile for OpenCode headroom..."))
        XCTAssertTrue(script.contains("/swapfile none swap sw 0 0"))
        XCTAssertTrue(script.contains("99-codeagents-keepalive.conf"))
        XCTAssertTrue(script.contains("ClientAliveInterval 30"))
        XCTAssertTrue(script.contains("ClientAliveCountMax 10"))
    }

    func testCloudInitStatusCommandCapturesErrorsWithoutFailingSSHCommand() {
        XCTAssertTrue(CloudInitStatus.statusCommand.contains("cloud-init status --long"))
        XCTAssertTrue(CloudInitStatus.statusCommand.contains("|| true"))
        XCTAssertEqual(CloudInitStatus.parse("status: done"), "done")
        XCTAssertEqual(CloudInitStatus.parse("status: error"), "error")
        XCTAssertEqual(CloudInitStatus.parse("status: running"), "running")
        XCTAssertEqual(CloudInitStatus.parse("status: disabled"), "done")
    }

    func testCloudInitDiagnosticsRedactsOpenCodePassword() {
        let diagnostics = """
        + OPENCODE_SERVER_PASSWORD="super_secret"
        OPENCODE_SERVER_PASSWORD=another_secret
        """

        let redacted = CloudInitStatus.redacted(diagnostics)

        XCTAssertFalse(redacted.contains("super_secret"))
        XCTAssertFalse(redacted.contains("another_secret"))
        XCTAssertTrue(redacted.contains("OPENCODE_SERVER_PASSWORD"))
    }

    func testGeneratedOpenCodePasswordIsEnvironmentSafe() throws {
        let password = try OpenCodeServerPasswordGenerator.generate(byteCount: 32)

        XCTAssertGreaterThanOrEqual(password.count, 40)
        XCTAssertNil(password.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
    }

    func testDaemonUnavailableDoesNotBlockForegroundOpenCodeChat() {
        let status = OpenCodeRuntimeSetupStatus.daemonUnavailable(
            version: "1.2.3",
            reason: "connection refused"
        )

        XCTAssertFalse(status.isReady)
        XCTAssertFalse(status.blocksForegroundChat)
        XCTAssertEqual(status.state, .daemonUnavailable)
    }
}
