//
//  ChatMessageAttachment.swift
//  CodeAgentsMobile
//
//  Purpose: Persisted chat attachment metadata for optimistic local previews + upload status.
//

import Foundation
import UniformTypeIdentifiers

enum ChatMessageAttachmentUploadStatus: String, Codable, Equatable {
    case pending
    case uploading
    case uploaded
    case failed
}

struct ChatMessageAttachment: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var displayName: String
    /// Local file path for thumbnails (device-only; may become stale after reinstall).
    var localPath: String?
    /// Remote `@`-less project-relative reference once uploaded / project-file selected.
    var remoteReference: String?
    var uploadStatus: ChatMessageAttachmentUploadStatus
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        localPath: String? = nil,
        remoteReference: String? = nil,
        uploadStatus: ChatMessageAttachmentUploadStatus = .pending,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.localPath = localPath
        self.remoteReference = remoteReference
        self.uploadStatus = uploadStatus
        self.errorMessage = errorMessage
    }

    var isImage: Bool {
        let ext = (displayName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .image)
    }

    static func fromComposer(_ attachment: ChatComposerAttachment) -> ChatMessageAttachment {
        switch attachment {
        case .projectFile(let id, let displayName, let relativePath):
            return ChatMessageAttachment(
                id: id,
                displayName: displayName,
                localPath: nil,
                remoteReference: relativePath,
                uploadStatus: .uploaded
            )
        case .localFile(let id, let displayName, let localURL):
            return ChatMessageAttachment(
                id: id,
                displayName: displayName,
                localPath: localURL.path,
                remoteReference: nil,
                uploadStatus: .pending
            )
        }
    }
}

enum ChatMessageAttachmentCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ attachments: [ChatMessageAttachment]) -> Data? {
        guard !attachments.isEmpty else { return nil }
        return try? encoder.encode(attachments)
    }

    static func decode(_ data: Data?) -> [ChatMessageAttachment] {
        guard let data, !data.isEmpty else { return [] }
        return (try? decoder.decode([ChatMessageAttachment].self, from: data)) ?? []
    }
}
