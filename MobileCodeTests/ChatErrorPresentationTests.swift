//
//  ChatErrorPresentationTests.swift
//  CodeAgentsMobileTests
//

import XCTest
@testable import CodeAgentsMobile

final class ChatErrorPresentationTests: XCTestCase {
    func testSplitsTitleAndDetail() {
        let parts = ChatErrorPresentation.parts(
            from: "Attachment upload failed: something went wrong"
        )
        XCTAssertEqual(parts.title, "Attachment upload failed")
        XCTAssertEqual(parts.detail, "something went wrong")
    }

    func testHumanizesNIOSSHNoise() {
        let parts = ChatErrorPresentation.parts(
            from: "Attachment upload failed: The operation couldn’t be completed. (NIOSSH.NIOSSHError error 1.)"
        )
        XCTAssertEqual(parts.title, "Attachment upload failed")
        XCTAssertEqual(
            parts.detail,
            "Connection to the server was interrupted. Check the network and try again."
        )
    }

    func testLegacyPrefixDetection() {
        XCTAssertTrue(
            ChatErrorPresentation.looksLikeLegacyLocalError(
                "Attachment upload failed: boom"
            )
        )
        XCTAssertFalse(
            ChatErrorPresentation.looksLikeLegacyLocalError(
                "Here is a normal assistant reply about attachments."
            )
        )
    }
}
