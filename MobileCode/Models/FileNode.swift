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
    
    var formattedSize: String? {
        guard let fileSize = fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}