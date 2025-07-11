//
//  ClaudeNotInstalledView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-11.
//
//  Purpose: Display installation instructions when Claude CLI is not installed
//

import SwiftUI

struct ClaudeNotInstalledView: View {
    let server: Server
    @State private var isChecking = false
    @State private var showCopiedFeedback = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            // Title
            Text("Claude CLI Not Installed")
                .font(.title2)
                .fontWeight(.medium)
            
            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("To use Claude chat, install Claude CLI on your server:")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                // Command box with copy button
                HStack {
                    Text("npm install -g @anthropic-ai/claude-code")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.vertical, 4)
                    
                    Spacer()
                    
                    Button(action: copyCommand) {
                        Text(showCopiedFeedback ? "Copied!" : "Copy")
                            .font(.footnote)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(showCopiedFeedback ? Color.green : Color.blue)
                            .cornerRadius(6)
                            .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }
            .frame(maxWidth: 400)
            
            // Check Again button
            Button(action: checkInstallation) {
                HStack {
                    if isChecking {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    }
                    Text(isChecking ? "Checking..." : "Check Again")
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(8)
            }
            .disabled(isChecking)
            
            // Additional help text
            Text("After installation, tap 'Check Again' to verify")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
    
    private func copyCommand() {
        UIPasteboard.general.string = "npm install -g @anthropic-ai/claude-code"
        
        // Show feedback
        withAnimation {
            showCopiedFeedback = true
        }
        
        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopiedFeedback = false
            }
        }
    }
    
    private func checkInstallation() {
        isChecking = true
        
        Task {
            // Perform the installation check
            _ = await ClaudeCodeService.shared.checkClaudeInstallation(for: server)
            
            // Reset checking state
            await MainActor.run {
                isChecking = false
            }
        }
    }
}

#Preview {
    ClaudeNotInstalledView(server: Server(
        name: "Demo Server",
        host: "demo.example.com",
        port: 22,
        username: "user",
        authMethodType: "password"
    ))
}