import XCTest
@testable import CodeAgentsMobile

final class SSHBase64TransferTests: XCTestCase {
    func testExtractMarkedPayloadExtractsBase64ContainingTTY() throws {
        let begin = "__CODEAGENTS_BASE64_BEGIN__"
        let end = "__CODEAGENTS_BASE64_END__"

        // Bytes chosen so base64 contains "TTY" ("TTYA").
        let originalData = Data([0x4D, 0x36, 0x00])
        let base64 = originalData.base64EncodedString()
        XCTAssertTrue(base64.contains("TTY"))

        let output = "banner line\n\(begin)\(base64)\(end)\ntrailing"
        let extracted = try SwiftSHSession.extractMarkedPayload(from: output, beginMarker: begin, endMarker: end)
        XCTAssertEqual(extracted, base64)

        let cleaned = extracted.components(separatedBy: .whitespacesAndNewlines).joined()
        let decoded = try XCTUnwrap(Data(base64Encoded: cleaned))
        XCTAssertEqual(decoded, originalData)
    }

    func testExtractMarkedPayloadAllowsWhitespaceInsidePayload() throws {
        let begin = "__CODEAGENTS_BASE64_BEGIN__"
        let end = "__CODEAGENTS_BASE64_END__"

        let originalData = Data((0..<64).map { UInt8($0) })
        let base64 = originalData.base64EncodedString()
        let base64WithNewlines = base64.prefix(12) + "\n" + base64.dropFirst(12).prefix(12) + "\n" + base64.dropFirst(24)

        let output = "\(begin)\(base64WithNewlines)\(end)"
        let extracted = try SwiftSHSession.extractMarkedPayload(from: output, beginMarker: begin, endMarker: end)
        let cleaned = extracted.components(separatedBy: .whitespacesAndNewlines).joined()
        let decoded = try XCTUnwrap(Data(base64Encoded: cleaned))
        XCTAssertEqual(decoded, originalData)
    }

    func testExtractMarkedPayloadThrowsWhenMissingBeginMarker() {
        XCTAssertThrowsError(
            try SwiftSHSession.extractMarkedPayload(
                from: "no markers here",
                beginMarker: "__CODEAGENTS_BASE64_BEGIN__",
                endMarker: "__CODEAGENTS_BASE64_END__"
            )
        ) { error in
            guard let sshError = error as? SSHError else {
                return XCTFail("Expected SSHError, got \(type(of: error))")
            }
            guard case .fileTransferFailed(let message) = sshError else {
                return XCTFail("Expected fileTransferFailed, got \(sshError)")
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("begin marker"))
        }
    }

    func testExtractMarkedPayloadThrowsWhenMissingEndMarker() {
        XCTAssertThrowsError(
            try SwiftSHSession.extractMarkedPayload(
                from: "__CODEAGENTS_BASE64_BEGIN__AAAA",
                beginMarker: "__CODEAGENTS_BASE64_BEGIN__",
                endMarker: "__CODEAGENTS_BASE64_END__"
            )
        ) { error in
            guard let sshError = error as? SSHError else {
                return XCTFail("Expected SSHError, got \(type(of: error))")
            }
            guard case .fileTransferFailed(let message) = sshError else {
                return XCTFail("Expected fileTransferFailed, got \(sshError)")
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("end marker"))
        }
    }
}

