//
//  ChatErrorBannerView.swift
//  CodeAgentsMobile
//
//  Purpose: Compact orange error notice for app-generated chat failures.
//

import SwiftUI

struct ChatErrorBannerView: View {
    let text: String

    private var parts: ChatErrorPresentation.Parts {
        ChatErrorPresentation.parts(from: text)
    }

    private let accent = Color.orange
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(parts.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = parts.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: UIScreen.main.bounds.width * 0.92, alignment: .leading)
        .modifier(ChatErrorBannerSurfaceModifier(accent: accent, shape: shape))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isStaticText)
    }

    private var accessibilityLabel: String {
        if let detail = parts.detail, !detail.isEmpty {
            return "Error. \(parts.title). \(detail)"
        }
        return "Error. \(parts.title)"
    }
}

// MARK: - Surface

private struct ChatErrorBannerSurfaceModifier: ViewModifier {
    let accent: Color
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(accent.opacity(0.22)), in: shape)
                .overlay(
                    shape.strokeBorder(accent.opacity(0.35), lineWidth: 0.8)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(accent.opacity(0.16), in: shape)
                .overlay(
                    shape.strokeBorder(accent.opacity(0.38), lineWidth: 0.8)
                )
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        ChatErrorBannerView(
            text: "Attachment upload failed: The operation couldn’t be completed. (NIOSSH.NIOSSHError error 1.)"
        )
        ChatErrorBannerView(text: "No active agent. Please select an agent first.")
    }
    .padding()
    .background(Color(.systemBackground))
}
