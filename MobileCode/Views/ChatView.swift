//
//  ChatView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @FocusState private var isInputFocused: Bool
    @State private var showingAttachments = false
    @State private var showingSettings = false
    @State private var isCheckingClaude = true
    @State private var claudeInstalled = false
    @State private var claudeCheckError: String?
    @State private var skipClaudeCheck = false
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var connectionManager = ConnectionManager.shared
    
    var body: some View {
        NavigationStack {
            Group {
                if isCheckingClaude {
                    ProgressView("Checking Claude Code installation...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !claudeInstalled && !skipClaudeCheck {
                    ClaudeNotInstalledView(error: claudeCheckError, onRetry: checkClaudeInstallation, skipCheck: $skipClaudeCheck)
                } else {
                    VStack(spacing: 0) {
                        // Messages List
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(viewModel.messages) { message in
                                        MessageBubble(message: message)
                                            .id(message.id)
                                    }
                                }
                                .padding()
                            }
                            .onChange(of: viewModel.messages.count) { oldValue, newValue in
                                withAnimation {
                                    if let lastMessage = viewModel.messages.last {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                                // Keep input focused after new messages
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isInputFocused = true
                                }
                            }
                        }
                        
                        Divider()
                        
                        // Input Bar
                        HStack(spacing: 12) {
                            Button {
                                showingAttachments = true
                            } label: {
                                Image(systemName: "paperclip")
                                    .font(.title3)
                                    .foregroundColor(.blue)
                            }
                            
                            TextField("Ask Claude...", text: $messageText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .focused($isInputFocused)
                                .lineLimit(1...5)
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                                .onSubmit {
                                    sendMessage()
                                }
                            
                            Button {
                                sendMessage()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.blue)
                            }
                            .disabled(messageText.isEmpty)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                    }
                    .onAppear {
                        // Focus input field when chat view appears
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isInputFocused = true
                        }
                    }
                }
            }
            .navigationTitle("Claude Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionStatusView()
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 16) {
                        Menu {
                            Button {
                                projectContext.clearActiveProject()
                            } label: {
                                Label("Back to Projects", systemImage: "arrow.backward")
                            }
                            
                            Divider()
                            
                            Button {
                                clearChat()
                            } label: {
                                Label("Clear Chat", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingAttachments) {
            AttachmentsSheet()
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .task {
            await checkClaudeInstallation()
        }
    }
    
    private func checkClaudeInstallation() async {
        isCheckingClaude = true
        claudeCheckError = nil
        
        guard let server = connectionManager.activeServer else {
            claudeCheckError = "No server connection"
            isCheckingClaude = false
            return
        }
        
        // Add timeout to prevent hanging
        let checkTask = Task {
            await viewModel.checkClaudeStatus(on: server)
        }
        
        do {
            // Wait for check with 10 second timeout
            let status = try await withThrowingTaskGroup(of: (installed: Bool, authenticated: Bool, error: String?).self) { group in
                group.addTask {
                    return await checkTask.value
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    throw CancellationError()
                }
                
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                
                throw CancellationError()
            }
            
            claudeInstalled = status.installed
            claudeCheckError = status.error
        } catch {
            claudeCheckError = "Installation check timed out"
            claudeInstalled = false
        }
        
        isCheckingClaude = false
        
        // Focus input field after Claude check completes
        if claudeInstalled || skipClaudeCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isInputFocused = true
            }
        }
    }
    
    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        
        let text = messageText
        messageText = ""
        
        // Keep focus on input field after sending
        isInputFocused = true
        
        Task {
            await viewModel.sendMessage(text)
        }
    }
    
    private func clearChat() {
        viewModel.clearChat()
    }
}

struct MessageBubble: View {
    let message: Message
    @State private var showingActions = false
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if let codeBlock = message.codeBlock {
                    VStack(alignment: .leading, spacing: 0) {
                        // Message text
                        if !message.content.isEmpty {
                            MessageContentView(content: message.content, isUser: message.role == .user)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(message.role == .user ? Color.blue : Color(.systemGray5))
                                .foregroundColor(message.role == .user ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                        }
                        
                        // Code block
                        CodeBlockView(code: codeBlock)
                    }
                } else {
                    MessageContentView(content: message.content, isUser: message.role == .user)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(message.role == .user ? Color.blue : Color(.systemGray5))
                        .foregroundColor(message.role == .user ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
                
                if message.role == .assistant {
                    HStack(spacing: 16) {
                        Button {
                            // Copy to clipboard
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Button {
                            // Regenerate
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == .user ? .trailing : .leading)
            
            if message.role == .assistant {
                Spacer()
            }
        }
    }
}

struct CodeBlockView: View {
    let code: Message.CodeBlock
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(code.language)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied!" : "Copy")
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            
            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.content)
                    .font(.custom("SF Mono", size: 14))
                    .padding(12)
            }
            .background(Color(.systemGray6))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .padding(.top, 8)
    }
    
    private func copyToClipboard() {
        UIPasteboard.general.string = code.content
        
        withAnimation {
            isCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

struct AttachmentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        // Attach file
                        dismiss()
                    } label: {
                        Label("Choose File", systemImage: "doc")
                    }
                    
                    Button {
                        // Take photo
                        dismiss()
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    
                    Button {
                        // Choose photo
                        dismiss()
                    } label: {
                        Label("Photo Library", systemImage: "photo")
                    }
                }
            }
            .navigationTitle("Add Attachment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ClaudeNotInstalledView: View {
    let error: String?
    let onRetry: () async -> Void
    @Binding var skipCheck: Bool
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Claude Code Not Found")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 12) {
                if let error = error {
                    Text(error)
                        .font(.body)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("Claude Code is not installed on the server.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Text("To install Claude Code, run this command on your server:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("npm install -g @anthropic-ai/claude-code")
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(.systemGray5))
                        .cornerRadius(8)
                        .textSelection(.enabled)
                }
                .padding(.horizontal)
                
                VStack(spacing: 8) {
                    Text("Requirements:")
                        .font(.headline)
                    
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Node.js 18 or later")
                            .font(.caption)
                    }
                    
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("4GB RAM minimum")
                            .font(.caption)
                    }
                    
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Internet connection")
                            .font(.caption)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)
            }
            
            HStack(spacing: 16) {
                Button {
                    Task {
                        await onRetry()
                    }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                        .padding()
                        .frame(maxWidth: 200)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                
                Button {
                    skipCheck = true
                } label: {
                    Text("Skip Check")
                        .padding()
                        .frame(maxWidth: 150)
                        .background(Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct MessageContentView: View {
    let content: String
    let isUser: Bool
    @State private var expandedSections: Set<String> = []
    @State private var showFullResults: Set<String> = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Parse content into sections
            ForEach(Array(parseSections().enumerated()), id: \.offset) { index, section in
                switch section {
                case .header(let icon, let title, let detail):
                    HeaderView(icon: icon, title: title, detail: detail)
                    
                case .turn(let number):
                    TurnMarkerView(turnNumber: number)
                    
                case .tool(let name, let id, let icon, let description):
                    ToolView(name: name, id: id, icon: icon, description: description)
                    
                case .toolResult(let id, let content, let isTruncated):
                    ToolResultView(
                        id: id,
                        content: content,
                        isTruncated: isTruncated,
                        isExpanded: expandedSections.contains(id),
                        showFullResult: showFullResults.contains(id),
                        onToggleExpand: { toggleSection(id) },
                        onToggleFullResult: { toggleFullResult(id) }
                    )
                    
                case .metadata(let icon, let label, let value):
                    MetadataView(icon: icon, label: label, value: value)
                    
                case .divider:
                    Divider()
                        .padding(.vertical, 4)
                    
                case .text(let text):
                    Text(text)
                        .font(.system(size: 16))
                        .textSelection(.enabled)
                    
                case .claudeMessage(let text):
                    ClaudeMessageView(text: text)
                    
                case .finalResponse:
                    FinalResponseHeaderView()
                }
            }
        }
    }
    
    private func toggleSection(_ id: String) {
        if expandedSections.contains(id) {
            expandedSections.remove(id)
        } else {
            expandedSections.insert(id)
        }
    }
    
    private func toggleFullResult(_ id: String) {
        if showFullResults.contains(id) {
            showFullResults.remove(id)
        } else {
            showFullResults.insert(id)
        }
    }
    
    // Parse content into structured sections
    private func parseSections() -> [ContentSection] {
        var sections: [ContentSection] = []
        let lines = content.components(separatedBy: "\n")
        
        for line in lines {
            if line.hasPrefix("🚀 **Claude initialized**") {
                sections.append(.header("🚀", "Claude initialized", nil))
            } else if line.hasPrefix("📍 Session ID:") {
                let sessionId = line.replacingOccurrences(of: "📍 Session ID: ", with: "")
                    .replacingOccurrences(of: "`", with: "")
                sections.append(.metadata("📍", "Session ID", sessionId))
            } else if line.hasPrefix("📦 Available tools:") {
                let toolCount = line.replacingOccurrences(of: "📦 Available tools: ", with: "")
                sections.append(.metadata("📦", "Available tools", toolCount))
            } else if line.hasPrefix("  • ") {
                // Tool category
                let category = line.replacingOccurrences(of: "  • ", with: "")
                sections.append(.text("  • " + category))
            } else if line.hasPrefix("**[Turn ") && line.contains("]**") {
                // Extract turn number
                if let turnStart = line.range(of: "Turn "),
                   let turnEnd = line.range(of: "]**") {
                    let turnStr = String(line[turnStart.upperBound..<turnEnd.lowerBound])
                    if let turnNum = Int(turnStr) {
                        sections.append(.turn(turnNum))
                    }
                }
            } else if line.hasPrefix("🔧 **Tool:") {
                let toolName = line.replacingOccurrences(of: "🔧 **Tool: ", with: "")
                    .replacingOccurrences(of: "**", with: "")
                let (icon, description) = getToolDetails(toolName)
                sections.append(.tool(toolName, nil, icon, description))
            } else if line.hasPrefix("🆔 Tool ID:") {
                let toolId = line.replacingOccurrences(of: "🆔 Tool ID: ", with: "")
                    .replacingOccurrences(of: "`", with: "")
                if case .tool(let name, _, let icon, let desc) = sections.last ?? .text("") {
                    sections[sections.count - 1] = .tool(name, toolId, icon, desc)
                }
            } else if line.hasPrefix("💻 ") || line.hasPrefix("📖 ") || line.hasPrefix("✏️ ") ||
                      line.hasPrefix("✂️ ") || line.hasPrefix("📂 ") || line.hasPrefix("🔍 ") {
                // Tool-specific description - already handled by tool section
                continue
            } else if line.hasPrefix("💭 Claude:") {
                let claudeText = line.replacingOccurrences(of: "💭 Claude: ", with: "")
                sections.append(.claudeMessage(claudeText))
            } else if line.hasPrefix("📊 Tokens:") {
                let tokens = line.replacingOccurrences(of: "📊 Tokens: ", with: "")
                sections.append(.metadata("📊", "Tokens", tokens))
            } else if line.hasPrefix("✅ **Tool result**") {
                if let idRange = line.range(of: "ID: `"),
                   let idEndRange = line.range(of: "`)\n", range: idRange.upperBound..<line.endIndex) {
                    let toolId = String(line[idRange.upperBound..<idEndRange.lowerBound])
                    sections.append(.toolResult(toolId, "", false))
                }
            } else if line.hasPrefix("📄 ") {
                // Tool result content
                let resultContent = line.replacingOccurrences(of: "📄 ", with: "")
                if case .toolResult(let id, _, _) = sections.last ?? .text("") {
                    let isTruncated = resultContent.hasSuffix("...")
                    sections[sections.count - 1] = .toolResult(id, resultContent, isTruncated)
                }
            } else if line.contains("*(Result truncated,") && line.contains("chars total)*") {
                // Update truncation status
                if case .toolResult(let id, let content, _) = sections.last ?? .text("") {
                    sections[sections.count - 1] = .toolResult(id, content, true)
                }
            } else if line.hasPrefix("⏱️ **Completed in") {
                let timing = line.replacingOccurrences(of: "⏱️ **", with: "")
                    .replacingOccurrences(of: "**", with: "")
                sections.append(.metadata("⏱️", "Timing", timing))
            } else if line.hasPrefix("💰 **Cost:") {
                let cost = line.replacingOccurrences(of: "💰 **Cost: ", with: "")
                    .replacingOccurrences(of: "**", with: "")
                sections.append(.metadata("💰", "Cost", cost))
            } else if line.hasPrefix("📊 **Total tokens:") {
                let tokens = line.replacingOccurrences(of: "📊 **Total tokens: ", with: "")
                    .replacingOccurrences(of: "**", with: "")
                sections.append(.metadata("📊", "Total tokens", tokens))
            } else if line == "---" {
                sections.append(.divider)
            } else if line == "**Final response:**" {
                sections.append(.finalResponse)
            } else if !line.isEmpty {
                sections.append(.text(line))
            }
        }
        
        return sections
    }
    
    private func getToolDetails(_ toolName: String) -> (icon: String, description: String) {
        switch toolName {
        case "Bash":
            return ("💻", "Execute shell command")
        case "Read":
            return ("📖", "Read file contents")
        case "Write":
            return ("✏️", "Write to file")
        case "Edit", "MultiEdit":
            return ("✂️", "Edit file contents")
        case "LS":
            return ("📂", "List directory")
        case "Grep":
            return ("🔍", "Search in files")
        case "Glob":
            return ("🔎", "Find files by pattern")
        case "Task":
            return ("🤖", "Launch sub-agent")
        case "TodoRead":
            return ("📋", "Read todo list")
        case "TodoWrite":
            return ("✅", "Update todo list")
        case "WebFetch":
            return ("🌐", "Fetch web content")
        case "WebSearch":
            return ("🔍", "Search the web")
        default:
            return ("🔧", "Tool operation")
        }
    }
}

// Content section types
enum ContentSection {
    case header(String, String, String?) // icon, title, detail
    case turn(Int)
    case tool(String, String?, String, String) // name, id, icon, description
    case toolResult(String, String, Bool) // id, content, isTruncated
    case metadata(String, String, String) // icon, label, value
    case divider
    case text(String)
    case claudeMessage(String)
    case finalResponse
}

// Individual view components
struct HeaderView: View {
    let icon: String
    let title: String
    let detail: String?
    
    var body: some View {
        HStack(spacing: 8) {
            Text(icon)
                .font(.system(size: 20))
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TurnMarkerView: View {
    let turnNumber: Int
    
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.blue.opacity(0.2))
                .frame(width: 4)
            Text("Turn \(turnNumber)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.blue)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct ToolView: View {
    let name: String
    let id: String?
    let icon: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(icon)
                    .font(.system(size: 18))
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                if let id = id {
                    Text("ID: \(id)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(4)
                }
                Spacer()
            }
            Text(description)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}

struct ToolResultView: View {
    let id: String
    let content: String
    let isTruncated: Bool
    let isExpanded: Bool
    let showFullResult: Bool
    let onToggleExpand: () -> Void
    let onToggleFullResult: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle")
                    .foregroundColor(.green)
                Text("Tool Result")
                    .font(.system(size: 14, weight: .medium))
                Text("ID: \(id)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if isTruncated && isExpanded {
                    Button(action: onToggleFullResult) {
                        Text(showFullResult ? "Show less" : "Show full")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }
            
            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 14, design: .monospaced))
                        .lineLimit(showFullResult ? nil : 5)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct MetadataView: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 8) {
            Text(icon)
                .font(.system(size: 16))
            Text(label + ":")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, design: label.contains("ID") || label.contains("tokens") ? .monospaced : .default))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct ClaudeMessageView: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.fill")
                .foregroundColor(.blue)
                .font(.system(size: 14))
            Text(text)
                .font(.system(size: 16))
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}

struct FinalResponseHeaderView: View {
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Final Response")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    ChatView()
}