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
    
    var icon: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        } else {
            switch name.split(separator: ".").last?.lowercased() {
            case "swift": return "swift"
            case "py": return "doc.text"
            case "js", "ts": return "doc.text"
            case "json": return "doc.text"
            case "md": return "doc.richtext"
            case "png", "jpg", "jpeg": return "photo"
            default: return "doc"
            }
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
    
    var formattedSize: String? {
        guard let fileSize = fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}
