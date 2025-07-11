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
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var claudeService = ClaudeCodeService.shared
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
            Group {
                // Check if Claude is installed
                if let server = projectContext.activeServer,
                   let isInstalled = claudeService.claudeInstallationStatus[server.id],
                   !isInstalled {
                    // Replace entire chat UI with installation view
                    ClaudeNotInstalledView(server: server)
                } else {
                    // Normal chat UI
                    VStack(spacing: 0) {
                        // Messages List
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(viewModel.messages) { message in
                                        MessageBubble(message: message, viewModel: viewModel)
                                            .id(message.id)
                                    }
                                }
                                .padding()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Dismiss keyboard when tapping on the chat area
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                            .onChange(of: viewModel.messages.count) { oldValue, newValue in
                                withAnimation {
                                    if let lastMessage = viewModel.messages.last {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                            // Also scroll when streaming blocks update
                            .onChange(of: viewModel.streamingBlocks.count) { oldValue, newValue in
                                if let streamingMessage = viewModel.streamingMessage {
                                    withAnimation {
                                        proxy.scrollTo(streamingMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                            // Scroll when streaming message content updates
                            .onChange(of: viewModel.streamingMessage?.originalJSON) { oldValue, newValue in
                                if let streamingMessage = viewModel.streamingMessage {
                                    withAnimation {
                                        proxy.scrollTo(streamingMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                                
                        
                        Divider()
                        
                        // Input Bar
                        HStack(spacing: 12) {
                            TextField("Ask Claude...", text: $messageText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
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
                }
            }
            .navigationTitle("Claude Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            clearChat()
                        } label: {
                            Label("Clear Chat", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
        .task {
            // Configure viewModel with current project
            if let project = projectContext.activeProject {
                viewModel.configure(modelContext: modelContext, projectId: project.id)
            }
        }
        .onAppear {
            // Re-check Claude installation when view appears
            Task {
                if let server = projectContext.activeServer {
                    // Only check if we don't have a cached status or if it was not installed
                    if claudeService.claudeInstallationStatus[server.id] == nil || 
                       claudeService.claudeInstallationStatus[server.id] == false {
                        await claudeService.checkClaudeInstallation(for: server)
                    }
                }
            }
        }
        .onChange(of: projectContext.activeProject) { oldValue, newValue in
            // Update viewModel when project changes
            if let project = newValue {
                viewModel.configure(modelContext: modelContext, projectId: project.id)
            }
        }
    }
    
    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        
        let text = messageText
        messageText = ""
        
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
    var viewModel: ChatViewModel
    
    var body: some View {
        // Check if this is the streaming message
        if viewModel.streamingMessage?.id == message.id {
            // First check if we have structured messages available
            if let messages = message.structuredMessages, !messages.isEmpty {
                // Use the same rendering as final messages
                // Group messages by type
                let assistantMessages = messages.filter { $0.type == "assistant" }
                let systemMessages = messages.filter { $0.type == "system" }
                let resultMessages = messages.filter { $0.type == "result" }
                let userMessages = messages.filter { $0.type == "user" }
                
                VStack(spacing: 8) {
                    // Show system messages
                    ForEach(Array(systemMessages.enumerated()), id: \.offset) { _, msg in
                        SystemMessageView(message: msg)
                    }
                    
                    // Show user or assistant messages (should be one type per Message object)
                    if !assistantMessages.isEmpty {
                        StructuredMessageBubble(message: message, structuredMessages: assistantMessages)
                    } else if !userMessages.isEmpty {
                        StructuredMessageBubble(message: message, structuredMessages: userMessages)
                    }
                    
                    // Show result messages
                    ForEach(Array(resultMessages.enumerated()), id: \.offset) { _, msg in
                        ResultMessageView(message: msg)
                    }
                }
            } else if !viewModel.streamingBlocks.isEmpty {
                // Fallback to streaming blocks if no structured messages yet
                VStack(spacing: 8) {
                    ForEach(0..<viewModel.streamingBlocks.count, id: \.self) { index in
                        let block = viewModel.streamingBlocks[index]
                        HStack {
                            if message.role == MessageRole.user {
                                Spacer()
                            }
                            
                            // Different styling for different block types
                            switch block {
                            case .text(let textBlock):
                                // Text blocks get the traditional bubble styling
                                TextBlockView(textBlock: textBlock, textColor: message.role == MessageRole.user ? .white : .primary, isStreaming: true)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                                    .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                                    .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                                    .transition(.opacity)
                                    .animation(.easeIn(duration: 0.2), value: viewModel.streamingBlocks.count)
                                
                            case .toolUse(_), .toolResult(_):
                                // Tool use and results get their own special styling
                                ContentBlockView(
                                    block: block, 
                                    textColor: .primary,
                                    isStreaming: true
                                )
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                                .transition(.opacity)
                                .animation(.easeIn(duration: 0.2), value: viewModel.streamingBlocks.count)
                            }
                            
                            if message.role == MessageRole.assistant && block.isTextBlock {
                                Spacer()
                            }
                        }
                    }
                }
            }
        } else {
        // Check if we have structured messages array
        if let messages = message.structuredMessages, !messages.isEmpty {
            // Group messages by type
            let assistantMessages = messages.filter { $0.type == "assistant" }
            let systemMessages = messages.filter { $0.type == "system" }
            let resultMessages = messages.filter { $0.type == "result" }
            let userMessages = messages.filter { $0.type == "user" }
            
            VStack(spacing: 8) {
                // Show system messages
                ForEach(Array(systemMessages.enumerated()), id: \.offset) { _, msg in
                    SystemMessageView(message: msg)
                }
                
                // Show user or assistant messages (should be one type per Message object)
                if !assistantMessages.isEmpty {
                    StructuredMessageBubble(message: message, structuredMessages: assistantMessages)
                } else if !userMessages.isEmpty {
                    StructuredMessageBubble(message: message, structuredMessages: userMessages)
                }
                
                // Show result messages
                ForEach(Array(resultMessages.enumerated()), id: \.offset) { _, msg in
                    ResultMessageView(message: msg)
                }
            }
        } else if let structured = message.structuredContent {
            // Legacy single message support
            switch structured.type {
            case "system":
                SystemMessageView(message: structured)
            case "result":
                ResultMessageView(message: structured)
            case "user", "assistant":
                StructuredMessageBubble(message: message, structuredMessages: [structured])
            default:
                // Fallback to plain text
                PlainMessageBubble(message: message)
            }
        } else {
            // Fallback to plain text for messages without structured content
            PlainMessageBubble(message: message)
        }
        }
    }
}

struct PlainMessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.role == MessageRole.user {
                Spacer()
            }
            
            Text(message.content)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
            
            if message.role == MessageRole.assistant {
                Spacer()
            }
        }
    }
}

struct StructuredMessageBubble: View {
    let message: Message
    let structuredMessages: [StructuredMessageContent]
    
    var body: some View {
        VStack(spacing: 8) {
            // Collect all content blocks from all messages
            let allBlocks = structuredMessages.compactMap { structured -> [ContentBlock]? in
                if let messageContent = structured.message {
                    switch messageContent.content {
                    case .text(let text):
                        return [ContentBlock.text(TextBlock(type: "text", text: text))]
                    case .blocks(let blocks):
                        return blocks
                    }
                }
                return nil
            }.flatMap { $0 }
            
            if !allBlocks.isEmpty {
                // Display each block as a separate bubble
                ForEach(Array(allBlocks.enumerated()), id: \.offset) { index, block in
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        // Different styling for different block types
                        switch block {
                        case .text(let textBlock):
                            // Text blocks get the traditional bubble styling
                            TextBlockView(textBlock: textBlock, textColor: message.role == MessageRole.user ? .white : .primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                                .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                            
                        case .toolUse(_), .toolResult(_):
                            // Tool use and results get their own special styling
                            ContentBlockView(
                                block: block, 
                                textColor: .primary
                            )
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                        }
                        
                        if message.role == MessageRole.assistant && block.isTextBlock {
                            Spacer()
                        }
                    }
                }
            } else {
                // Fallback to plain text if no blocks
                HStack {
                    if message.role == MessageRole.user {
                        Spacer()
                    }
                    
                    Text(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                        .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                    
                    if message.role == MessageRole.assistant {
                        Spacer()
                    }
                }
            }
        }
    }
}

// Helper extension to check block type
extension ContentBlock {
    var isTextBlock: Bool {
        switch self {
        case .text(_):
            return true
        default:
            return false
        }
    }
}


#Preview {
    ChatView()
}