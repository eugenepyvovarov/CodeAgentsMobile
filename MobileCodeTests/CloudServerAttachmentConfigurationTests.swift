import XCTest
@testable import CodeAgentsMobile

final class CloudServerAttachmentConfigurationTests: XCTestCase {
    func testAttachedCloudServerDoesNotNeedCloudInitMonitoring() {
        let provider = ServerProvider(providerType: "hetzner", name: "Hetzner")
        let checkedAt = Date(timeIntervalSince1970: 1_777_744_800)
        let cloudServer = CloudServer(
            id: "provider-server-1",
            name: "opencode",
            status: "running",
            publicIP: "203.0.113.10",
            privateIP: nil,
            region: "fsn1",
            imageInfo: "Ubuntu 24.04",
            sizeInfo: "cx22",
            providerType: "hetzner"
        )

        let server = CloudServerAttachmentConfiguration.makeAttachedServer(
            cloudServer: cloudServer,
            provider: provider,
            displayName: "",
            username: "root",
            authMethodType: "key",
            sshKeyId: UUID(),
            now: checkedAt
        )

        XCTAssertEqual(server.name, "opencode")
        XCTAssertEqual(server.host, "203.0.113.10")
        XCTAssertEqual(server.providerId, provider.id)
        XCTAssertEqual(server.providerServerId, "provider-server-1")
        XCTAssertTrue(server.cloudInitComplete)
        XCTAssertEqual(server.cloudInitStatus, "done")
        XCTAssertEqual(server.cloudInitLastChecked, checkedAt)
    }

    func testOpenCodeAuthConfigurationRequiresPasswordWhenEnabled() {
        var configuration = OpenCodeServerAuthConfiguration()

        XCTAssertTrue(configuration.canSave)
        XCTAssertNil(configuration.credentials)

        configuration.isEnabled = true
        XCTAssertFalse(configuration.canSave)
        XCTAssertNil(configuration.credentials)

        configuration.username = "  "
        configuration.password = "secret"

        XCTAssertTrue(configuration.canSave)
        XCTAssertEqual(configuration.credentials?.username, OpenCodeServerProvisioning.username)
        XCTAssertEqual(configuration.credentials?.password, "secret")
    }
}
