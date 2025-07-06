//
//  DiffView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-06.
//

import SwiftUI

struct DiffView: View {
    let oldString: String
    let newString: String
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                    DiffLineView(line: line)
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
    }
    
    private var diffLines: [DiffLine] {
        let oldLines = oldString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        
        // Simple diff algorithm - just show changes line by line
        while i < oldLines.count || j < newLines.count {
            if i >= oldLines.count {
                // Remaining new lines
                result.append(.added(newLines[j]))
                j += 1
            } else if j >= newLines.count {
                // Remaining old lines
                result.append(.removed(oldLines[i]))
                i += 1
            } else if oldLines[i] == newLines[j] {
                // Same line
                if result.count < 3 || i >= oldLines.count - 3 || j >= newLines.count - 3 {
                    result.append(.unchanged(oldLines[i]))
                } else if result.last?.isUnchanged != true {
                    result.append(.ellipsis)
                }
                i += 1
                j += 1
            } else {
                // Different lines
                result.append(.removed(oldLines[i]))
                result.append(.added(newLines[j]))
                i += 1
                j += 1
            }
        }
        
        return result
    }
}

enum DiffLine {
    case added(String)
    case removed(String)
    case unchanged(String)
    case ellipsis
    
    var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

struct DiffLineView: View {
    let line: DiffLine
    
    var body: some View {
        HStack(spacing: 4) {
            Text(prefix)
                .foregroundColor(prefixColor)
                .frame(width: 12, alignment: .center)
            
            Text(content)
                .foregroundColor(contentColor)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .fixedSize(horizontal: true, vertical: false)
    }
    
    private var prefix: String {
        switch line {
        case .added: return "+"
        case .removed: return "-"
        case .unchanged: return " "
        case .ellipsis: return "..."
        }
    }
    
    private var prefixColor: Color {
        switch line {
        case .added: return .green
        case .removed: return .red
        case .unchanged, .ellipsis: return .secondary
        }
    }
    
    private var content: String {
        switch line {
        case .added(let text), .removed(let text), .unchanged(let text):
            return text
        case .ellipsis:
            return ""
        }
    }
    
    private var contentColor: Color {
        switch line {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .primary
        case .ellipsis: return .secondary
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        DiffView(
            oldString: "def hello():\n    print('Hello')\n    return True",
            newString: "def hello():\n    print('Hello World')\n    return True"
        )
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
        
        DiffView(
            oldString: "@app.get('/users')\ndef get_users():\n    return users",
            newString: "@app.get('/users')\ndef get_users(current_user: User = Depends(auth)):\n    return users"
        )
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
    .padding()
}