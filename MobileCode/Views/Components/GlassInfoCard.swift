//
//  GlassInfoCard.swift
//  CodeAgentsMobile
//
//  Purpose: Reusable info card with Liquid Glass fallback
//

import SwiftUI

struct GlassInfoCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)), in: .rect(cornerRadius: 16))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
                    )
            }
        }
    }
}

#Preview {
    GlassInfoCard(title: "Global Skills",
                  subtitle: "Install once, then add to any agent.",
                  systemImage: "sparkles")
        .padding()
}
