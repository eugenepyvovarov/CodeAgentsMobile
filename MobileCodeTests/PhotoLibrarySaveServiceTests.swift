//
//  PhotoLibrarySaveServiceTests.swift
//  CodeAgentsMobileTests
//

import XCTest
@testable import CodeAgentsMobile

final class PhotoLibrarySaveServiceTests: XCTestCase {
    func testMediaKindDetectsCommonImages() {
        XCTAssertEqual(
            PhotoLibrarySaveService.mediaKind(for: URL(fileURLWithPath: "/tmp/a.jpg")),
            .image
        )
        XCTAssertEqual(
            PhotoLibrarySaveService.mediaKind(for: URL(fileURLWithPath: "/tmp/a.PNG")),
            .image
        )
        XCTAssertEqual(
            PhotoLibrarySaveService.mediaKind(for: URL(fileURLWithPath: "/tmp/a.heic")),
            .image
        )
    }

    func testMediaKindDetectsCommonVideos() {
        XCTAssertEqual(
            PhotoLibrarySaveService.mediaKind(for: URL(fileURLWithPath: "/tmp/a.mp4")),
            .video
        )
        XCTAssertEqual(
            PhotoLibrarySaveService.mediaKind(for: URL(fileURLWithPath: "/tmp/a.MOV")),
            .video
        )
    }

    func testMediaKindRejectsNonMedia() {
        XCTAssertNil(PhotoLibrarySaveService.mediaKind(for: URL(fileURLWithPath: "/tmp/a.swift")))
        XCTAssertNil(PhotoLibrarySaveService.mediaKind(for: URL(fileURLWithPath: "/tmp/readme.md")))
        XCTAssertFalse(PhotoLibrarySaveService.canSaveToPhotos(url: URL(fileURLWithPath: "/tmp/a.json")))
    }
}
