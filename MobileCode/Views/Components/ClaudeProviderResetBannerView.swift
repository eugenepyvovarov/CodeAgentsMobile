//
//  ClaudeProviderResetBannerView.swift
//  CodeAgentsMobile
//
//  Purpose: Interactive banner shown when the user switches Claude providers and the current
//  chat/task session needs to be reset before continuing.
//

import SwiftUI

struct ClaudeProviderResetBannerView: View {
    let mismatch: ClaudeProviderMismatch
    let onClearChat: () -> Void
    let onChangeProvider: () -> Void

    var body: some View {
        let content = HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(mismatch.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                Text(mismatch.message)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button(role: .destructive, action: onClearChat) {
                        Label("Clear Chat", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }

                    Button(action: onChangeProvider) {
                        Label("Change Provider", systemImage: "gearshape")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(14)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(Color.orange.opacity(0.14)), in: .rect(cornerRadius: 14))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.orange.opacity(0.25), lineWidth: 0.7)
                    )
            }
        }
    }
}

#Preview {
    ClaudeProviderResetBannerView(
        mismatch: ClaudeProviderMismatch(previous: .miniMax, current: .anthropic),
        onClearChat: {},
        onChangeProvider: {}
    )
    .padding()
}

