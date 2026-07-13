//
//  UploadFilenameTests.swift
//  CodeAgentsMobileTests
//
//  Purpose: Filename sanitization and asset-id rejection for uploads.
//

import Foundation
import Testing
@testable import CodeAgentsMobile

struct UploadFilenameTests {

    @Test func detectsPhotoKitStyleAssetIdentifiers() {
        #expect(UploadFilename.isLikelyAssetIdentifier("9F3A2C1B-4D5E-6789-ABCD-EF0123456789.jpg"))
        #expect(UploadFilename.isLikelyAssetIdentifier("A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
        #expect(!UploadFilename.isLikelyAssetIdentifier("IMG_1234.JPG"))
        #expect(!UploadFilename.isLikelyAssetIdentifier("vacation-photo.jpg"))
        #expect(!UploadFilename.isLikelyAssetIdentifier("short.jpg"))
        #expect(!UploadFilename.isLikelyAssetIdentifier("Photo-20260101-120000.jpg"))
    }

    @Test func prefersReadableNamesOverAssetIds() {
        let fromAsset = UploadFilename.humanDisplayName(
            preferred: "9F3A2C1B-4D5E-6789-ABCD-EF0123456789.jpg",
            fallbackStem: "Photo",
            preferredExtension: "jpg"
        )
        #expect(fromAsset.hasPrefix("Photo-"))
        #expect(fromAsset.hasSuffix(".jpg"))
        #expect(!UploadFilename.isLikelyAssetIdentifier(fromAsset))

        let fromReadable = UploadFilename.humanDisplayName(
            preferred: "My Beach Day.png",
            fallbackStem: "Photo",
            preferredExtension: "jpg"
        )
        #expect(fromReadable == "My-Beach-Day.jpg")
    }

    @Test func uniqueAvoidsCollisions() {
        let taken: Set<String> = ["Photo.jpg", "Photo-2.jpg"]
        #expect(UploadFilename.unique(originalName: "Photo.jpg", taken: taken) == "Photo-3.jpg")
        #expect(UploadFilename.unique(originalName: "Other.jpg", taken: taken) == "Other.jpg")
    }

    @Test func sanitizeStemStripsUnsafeCharacters() {
        #expect(UploadFilename.sanitizeStem("hello world!!") == "hello-world")
        #expect(UploadFilename.sanitizeStem("  --ab__c--  ") == "ab__c")
        #expect(UploadFilename.sanitizeStem("").isEmpty)
    }

    @Test func mediaKindHelpers() {
        #expect(MediaUploadStager.kind(forExtension: "jpg") == .image)
        #expect(MediaUploadStager.kind(forExtension: "MP4") == .video)
        #expect(MediaUploadStager.kind(forExtension: "swift") == .file)
    }

    @Test func fileNodeMediaDetection() {
        let image = FileNode(name: "shot.heic", path: "/a/shot.heic", isDirectory: false, fileSize: 100, modificationDate: nil)
        let video = FileNode(name: "clip.mov", path: "/a/clip.mov", isDirectory: false, fileSize: 100, modificationDate: nil)
        let folder = FileNode(name: "pics", path: "/a/pics", isDirectory: true, fileSize: nil, modificationDate: nil)
        #expect(image.isImageFile)
        #expect(image.isMediaFile)
        #expect(video.isVideoFile)
        #expect(video.isMediaFile)
        #expect(!folder.isMediaFile)
    }
}
