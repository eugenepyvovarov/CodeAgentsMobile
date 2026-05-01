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
        XCTAssertFalse(cloudInit.contains("@anthropic-ai/claude-code"))
        XCTAssertFalse(cloudInit.contains("{{"))
    }

    func testOpenCodeEnvironmentFileCanOmitPassword() {
        let environment = OpenCodeServerProvisioning.environmentFile(password: nil)

        XCTAssertTrue(environment.contains("OPENCODE_SERVER_USERNAME=\"opencode\""))
        XCTAssertFalse(environment.contains("OPENCODE_SERVER_PASSWORD"))
    }

    func testGeneratedOpenCodePasswordIsEnvironmentSafe() throws {
        let password = try OpenCodeServerPasswordGenerator.generate(byteCount: 32)

        XCTAssertGreaterThanOrEqual(password.count, 40)
        XCTAssertNil(password.range(of: #"[^A-Za-z0-9_-]"#, options: .regularExpression))
    }
}
