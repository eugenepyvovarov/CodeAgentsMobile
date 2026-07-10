import XCTest
@testable import CodeAgentsMobile

final class SSHHostKeyStoreTests: XCTestCase {
    func testFingerprintIsStableForSameMaterial() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJustATestKeyMaterialNotReal==== comment"
        let a = SSHHostKeyStore.fingerprint(openSSHKey: key)
        let b = SSHHostKeyStore.fingerprint(openSSHKey: key)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("SHA256:"))
    }

    func testHostIdentityAccountIsStable() {
        let id = SSHHostKeyStore.HostIdentity(host: "Example.COM", port: 22)
        XCTAssertEqual(id.account, "ssh.hostkey.example.com:22")
        XCTAssertEqual(id.displayName, "Example.COM")
        let nonDefault = SSHHostKeyStore.HostIdentity(host: "10.0.0.1", port: 2222)
        XCTAssertEqual(nonDefault.displayName, "10.0.0.1:2222")
    }
}
