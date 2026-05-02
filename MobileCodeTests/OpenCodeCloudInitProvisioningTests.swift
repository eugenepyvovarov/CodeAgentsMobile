import XCTest
@testable import CodeAgentsMobile

final class OpenCodeCloudInitProvisioningTests: XCTestCase {
    func testGeneratedCloudInitInstallsAndStartsOpenCodeServer() throws {
        let cloudInit = try XCTUnwrap(CloudInitTemplate.generate(
            with: ["ssh-ed25519 AAAAFixture test@example.com"],
            openCodeServerPassword: "fixture_password"
        ))

        XCTAssertTrue(cloudInit.contains("ssh-ed25519 AAAAFixture test@example.com"))
        XCTAssertTrue(cloudInit.contains("curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"))
        XCTAssertTrue(cloudInit.contains("opencode serve --hostname 127.0.0.1 --port 4096"))
        XCTAssertTrue(cloudInit.contains("systemctl enable --now opencode"))
        XCTAssertTrue(cloudInit.contains("http://127.0.0.1:4096/global/health"))
        XCTAssertTrue(cloudInit.contains("OPENCODE_SERVER_PASSWORD=\"fixture_password\""))
        XCTAssertTrue(cloudInit.contains("SERVICE_NAME=codeagents-daemon"))
        XCTAssertTrue(cloudInit.contains("INSTALL_DIR=/opt/codeagents-daemon"))
        XCTAssertTrue(cloudInit.contains("INSTALL_CLAUDE_CLI=0"))
        XCTAssertTrue(cloudInit.contains("http://127.0.0.1:8787/healthz"))
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
        XCTAssertTrue(script.contains("curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"))
        XCTAssertTrue(script.contains("cat > /etc/opencode-server.env"))
        XCTAssertTrue(script.contains("OPENCODE_SERVER_USERNAME=\"mobile\""))
        XCTAssertTrue(script.contains("OPENCODE_SERVER_PASSWORD=\"fixture_password\""))
        XCTAssertTrue(script.contains("cat > /etc/systemd/system/opencode.service"))
        XCTAssertTrue(script.contains("systemctl enable --now opencode"))
        XCTAssertTrue(script.contains("http://127.0.0.1:4096/global/health"))
        XCTAssertTrue(script.contains("SERVICE_NAME=codeagents-daemon"))
        XCTAssertTrue(script.contains("INSTALL_DIR=/opt/codeagents-daemon"))
        XCTAssertTrue(script.contains("INSTALL_CLAUDE_CLI=0"))
        XCTAssertTrue(script.contains("http://127.0.0.1:8787/healthz"))
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
