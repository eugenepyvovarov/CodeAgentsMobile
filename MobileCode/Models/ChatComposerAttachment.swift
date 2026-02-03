//
//  ChatComposerAttachment.swift
//  CodeAgentsMobile
//
//  Purpose: Represents user-selected attachments for the chat composer (skills, project files, local files).
//

import Foundation
import UniformTypeIdentifiers

enum ChatComposerAttachment: Hashable, Identifiable {
    case projectFile(id: UUID = UUID(), displayName: String, relativePath: String)
    case localFile(id: UUID = UUID(), displayName: String, localURL: URL)

    var id: UUID {
        switch self {
        case .projectFile(let id, _, _):
            return id
        case .localFile(let id, _, _):
            return id
        }
    }

    var displayName: String {
        switch self {
        case .projectFile(_, let displayName, _):
            return displayName
        case .localFile(_, let displayName, _):
            return displayName
        }
    }

    var relativeReferencePath: String? {
        switch self {
        case .projectFile(_, _, let relativePath):
            return relativePath
        case .localFile:
            return nil
        }
    }

    var systemImageName: String {
        isImageAttachment ? "photo" : "doc"
    }

    private var isImageAttachment: Bool {
        let ext = (displayName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .image)
    }
}
