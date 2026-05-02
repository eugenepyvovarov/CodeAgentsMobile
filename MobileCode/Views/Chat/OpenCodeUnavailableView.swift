//
//  OpenCodeUnavailableView.swift
//  CodeAgentsMobile
//
//  Purpose: Display OpenCode runtime readiness issues for the active chat.
//

import SwiftUI

struct OpenCodeUnavailableView: View {
    let server: Server
    let status: OpenCodeRuntimeSetupStatus
    let isChecking: Bool
    let onCheckAgain: () -> Void
    let onOpenServerSettings: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 56))
                .foregroundColor(iconColor)

            Text(title)
                .font(.title2)
                .fontWeight(.medium)

            Text(status.message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(spacing: 12) {
                Button(action: onCheckAgain) {
                    HStack {
                        if isChecking {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        }
                        Text(isChecking ? "Checking..." : "Check Again")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)

                Button(action: onOpenServerSettings) {
                    Label("Open Server Settings", systemImage: "server.rack")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
            }

            Text("\(server.name) · \(server.host)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var title: String {
        switch status.state {
        case .authRequired:
            return "OpenCode Auth Required"
        case .notInstalled:
            return "OpenCode Not Installed"
        case .notRunning:
            return "OpenCode Not Running"
        case .unreachable:
            return "OpenCode Unreachable"
        case .sshUnavailable:
            return "Server Connection Failed"
        case .unknown:
            return "OpenCode Status Unknown"
        case .available:
            return "OpenCode Ready"
        }
    }

    private var iconName: String {
        switch status.state {
        case .authRequired:
            return "lock.circle"
        case .notInstalled:
            return "arrow.down.circle"
        case .notRunning:
            return "pause.circle"
        case .unreachable, .sshUnavailable:
            return "xmark.circle"
        case .unknown:
            return "questionmark.circle"
        case .available:
            return "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch status.state {
        case .available:
            return .green
        case .authRequired, .notInstalled, .notRunning:
            return .orange
        case .unreachable, .sshUnavailable:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

#Preview {
    OpenCodeUnavailableView(
        server: Server(name: "Demo Server", host: "demo.example.com", username: "user"),
        status: .notInstalled(),
        isChecking: false,
        onCheckAgain: {},
        onOpenServerSettings: {}
    )
}
