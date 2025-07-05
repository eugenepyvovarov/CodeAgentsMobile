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
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
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
            }
        }
        .task {
            // Configure viewModel with current project
            if let project = projectContext.activeProject {
                viewModel.configure(modelContext: modelContext, projectId: project.id)
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


#Preview {
    ChatView()
}