import XCTest
@testable import CodeAgentsMobile

final class SSHShellQuotingTests: XCTestCase {
    func testQuoteEscapesApostrophes() {
        XCTAssertEqual(SSHShellQuoting.quote("foo"), "'foo'")
        XCTAssertEqual(SSHShellQuoting.quote("a'b"), "'a'\\''b'")
        XCTAssertEqual(SSHShellQuoting.quote(""), "''")
    }

    func testSafePathComponentRejectsTraversalAndControls() {
        XCTAssertTrue(SSHShellQuoting.isSafePathComponent("my-agent"))
        XCTAssertTrue(SSHShellQuoting.isSafePathComponent("My Agent"))
        XCTAssertFalse(SSHShellQuoting.isSafePathComponent(""))
        XCTAssertFalse(SSHShellQuoting.isSafePathComponent("."))
        XCTAssertFalse(SSHShellQuoting.isSafePathComponent(".."))
        XCTAssertFalse(SSHShellQuoting.isSafePathComponent("a/b"))
        XCTAssertFalse(SSHShellQuoting.isSafePathComponent("a\\b"))
        XCTAssertFalse(SSHShellQuoting.isSafePathComponent("a\nb"))
        XCTAssertNil(SSHShellQuoting.sanitizedPathComponent("  "))
        XCTAssertEqual(SSHShellQuoting.sanitizedPathComponent("  ok  "), "ok")
    }
}
