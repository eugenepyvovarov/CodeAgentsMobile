//
//  StreamingBlockViews.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-06.
//

import SwiftUI

// MARK: - Streaming Text Block
struct StreamingTextBlock: View {
    let text: String
    let textColor: Color
    @State private var showCursor = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                FullMarkdownTextView(text: text, textColor: textColor)
                
                if showCursor {
                    Text("|")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(textColor.opacity(0.6))
                        .offset(y: -2)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                showCursor.toggle()
            }
        }
    }
}

// MARK: - Streaming Tool Use Block
struct StreamingToolUseBlock: View {
    let toolName: String
    let parameters: [String: Any]
    @State private var rotation: Double = 0
    
    var body: some View {
        HStack(spacing: 12) {
            // Tool icon with rotation animation
            Image(systemName: getToolIcon(for: toolName))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.blue)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(toolName)
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.medium)
                
                if let command = parameters["command"] as? String {
                    Text(command)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if let path = parameters["path"] as? String ?? parameters["file_path"] as? String {
                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !parameters.isEmpty {
                    Text("\(parameters.count) parameters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Running...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func getToolIcon(for tool: String) -> String {
        switch tool.lowercased() {
        case "todowrite", "todoread":
            return "checklist"
        case "read":
            return "doc.text"
        case "write", "edit", "multiedit":
            return "square.and.pencil"
        case "bash":
            return "terminal"
        case "grep", "glob", "ls":
            return "magnifyingglass"
        case "webfetch", "websearch":
            return "globe"
        default:
            return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Streaming Tool Result Block
struct StreamingToolResultBlock: View {
    let toolUseId: String
    let isError: Bool
    let content: String
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                if !content.isEmpty {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isError ? "xmark.circle" : "checkmark.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isError ? .red : .green)
                    
                    Text("Tool Result")
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if !content.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            // Show content if available and expanded
            if !content.isEmpty && isExpanded {
                Text(content)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundColor(isError ? .red : .primary)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !content.isEmpty && !isExpanded {
                // Show preview when collapsed
                Text(content.split(separator: "\n").first.map(String.init) ?? content)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 24)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isError ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Streaming System Block
struct StreamingSystemBlock: View {
    let sessionId: String?
    let cwd: String?
    let model: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
                
                Text("Session Starting...")
                    .font(.system(.caption, design: .rounded))
                    .fontWeight(.medium)
                
                Spacer()
                
                ProgressView()
                    .scaleEffect(0.7)
            }
            
            if let cwd = cwd {
                HStack(spacing: 4) {
                    Text("Directory:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(cwd)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 16) {
        StreamingTextBlock(
            text: "I'll help you implement **markdown** formatting",
            textColor: .primary
        )
        
        StreamingToolUseBlock(
            toolName: "TodoWrite",
            parameters: ["todos": []]
        )
        
        StreamingToolResultBlock(
            toolUseId: "tool_123",
            isError: false,
            content: "Task completed successfully"
        )
        
        StreamingSystemBlock(
            sessionId: "abc-123",
            cwd: "/root/projects",
            model: "claude-3"
        )
    }
    .padding()
}