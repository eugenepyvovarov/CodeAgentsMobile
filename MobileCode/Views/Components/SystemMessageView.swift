//
//  SystemMessageView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import SwiftUI

struct SystemMessageView: View {
    let message: StructuredMessageContent
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.blue)
                    
                    Text("Session Info")
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let sessionId = message.sessionId {
                        HStack(spacing: 4) {
                            Text("Session:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(sessionId.prefix(8) + "...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let data = message.data {
                        if let cwd = data["cwd"] as? String {
                            HStack(spacing: 4) {
                                Text("Directory:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(BlockFormattingUtils.formatFilePath(cwd))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let model = data["model"] as? String {
                            HStack(spacing: 4) {
                                Text("Model:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(model)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let tools = data["tools"] as? [String], !tools.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Available tools:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(tools.joined(separator: ", "))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ResultMessageView: View {
    let message: StructuredMessageContent
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: message.isError == true ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(message.isError == true ? .red : .green)
                    
                    Text("Session Complete")
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    // Quick stats
                    if let duration = message.durationMs {
                        Text(BlockFormattingUtils.formatDuration(duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let cost = message.totalCostUsd {
                        Text(BlockFormattingUtils.formatCost(cost))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Stats
                    HStack(spacing: 20) {
                        if let duration = message.durationMs {
                            Label(BlockFormattingUtils.formatDuration(duration), systemImage: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let cost = message.totalCostUsd {
                            Label(BlockFormattingUtils.formatCost(cost), systemImage: "dollarsign.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let numTurns = message.numTurns {
                            Label("\(numTurns) turns", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let usage = message.usage {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble")
                                .font(.caption)
                            Text("\(usage.inputTokens ?? 0) in / \(usage.outputTokens ?? 0) out")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    // Result text if present
                    if let result = message.result, !result.isEmpty {
                        Divider()
                        ScrollView {
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                }
            }
        }
        .padding(12)
        .background(message.isError == true ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
        .cornerRadius(8)
    }
}