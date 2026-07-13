//
//  FileNode.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-04.
//
//  Purpose: Data model for file browser nodes
//

import Foundation

struct FileNode: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileNode]?
    let fileSize: Int64?
    let modificationDate: Date?
    var isExpanded: Bool = false

    private static let textFileExtensions: Set<String> = [
        "swift", "m", "mm",
        "c", "h", "hpp", "cpp",
        "js", "jsx", "ts", "tsx",
        "json",
        "md", "mdx", "txt", "rtf",
        "yaml", "yml", "toml",
        "xml", "html", "css", "scss",
        "py", "rb", "go", "rs", "kt", "kts", "java",
        "sql", "sh", "bash", "zsh",
        "ini", "cfg", "conf", "log", "csv"
    ]

    static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"
    ]

    static let videoFileExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm"
    ]
    
    var icon: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        if isImageFile { return "photo" }
        if isVideoFile { return "film" }
        switch fileExtension {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "ts", "tsx", "jsx": return "doc.text"
        case "json": return "curlybraces"
        case "md", "mdx": return "doc.richtext"
        case "pdf": return "doc.richtext.fill"
        default: return "doc"
        }
    }

    var fileExtension: String? {
        let ext = (name as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? nil : ext.lowercased()
    }

    var isTextFile: Bool {
        guard !isDirectory, let ext = fileExtension else { return false }
        return FileNode.textFileExtensions.contains(ext)
    }

    var isImageFile: Bool {
        guard !isDirectory, let ext = fileExtension else { return false }
        return FileNode.imageFileExtensions.contains(ext)
    }

    var isVideoFile: Bool {
        guard !isDirectory, let ext = fileExtension else { return false }
        return FileNode.videoFileExtensions.contains(ext)
    }

    var isMediaFile: Bool {
        isImageFile || isVideoFile
    }
    
    var formattedSize: String? {
        guard let fileSize = fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}
