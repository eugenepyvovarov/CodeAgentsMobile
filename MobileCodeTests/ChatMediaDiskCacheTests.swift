//
//  ChatMediaDiskCacheTests.swift
//  CodeAgentsMobileTests
//
//  Purpose: Durable chat media cache keys + store/lookup.
//

import Foundation
import Testing
@testable import CodeAgentsMobile

struct ChatMediaDiskCacheTests {

    @Test func stableKeyProducesSamePath() {
        let key = "project:ABC:super-generated-images/clip.mp4"
        let a = ChatMediaDiskCache.fileURL(forKey: key, pathExtension: "mp4")
        let b = ChatMediaDiskCache.fileURL(forKey: key, pathExtension: "mp4")
        #expect(a.path == b.path)
        #expect(a.pathExtension == "mp4")
        #expect(a.lastPathComponent.count > 20)
    }

    @Test func differentKeysProduceDifferentPaths() {
        let a = ChatMediaDiskCache.fileURL(forKey: "url:https://a.example/x.jpg", pathExtension: "jpg")
        let b = ChatMediaDiskCache.fileURL(forKey: "url:https://b.example/x.jpg", pathExtension: "jpg")
        #expect(a.path != b.path)
    }

    @Test func storeAndLookupRoundTrip() throws {
        let key = "test:\(UUID().uuidString)"
        let payload = Data("chat-media-cache-test".utf8)
        let stored = try ChatMediaDiskCache.storeData(payload, forKey: key, pathExtension: "bin")
        #expect(FileManager.default.fileExists(atPath: stored.path))

        let found = ChatMediaDiskCache.existingFile(forKey: key, pathExtension: "bin")
        #expect(found?.path == stored.path)

        let byDigestOnly = ChatMediaDiskCache.existingFile(forKey: key)
        #expect(byDigestOnly?.path == stored.path)

        let bytes = try Data(contentsOf: stored)
        #expect(bytes == payload)

        try? FileManager.default.removeItem(at: stored)
    }

    @Test func sha256IsDeterministic() {
        #expect(ChatMediaDiskCache.sha256Hex("hello") == ChatMediaDiskCache.sha256Hex("hello"))
        #expect(ChatMediaDiskCache.sha256Hex("hello") != ChatMediaDiskCache.sha256Hex("world"))
        #expect(ChatMediaDiskCache.sha256Hex(Data("hello".utf8)) == ChatMediaDiskCache.sha256Hex("hello"))
    }
}
