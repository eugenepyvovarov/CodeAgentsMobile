//
//  AgentAvatarView.swift
//  CodeAgentsMobile
//
//  Purpose: Circular avatar for Agents list / Abilities (monogram, emoji, or image).
//

import SwiftUI
import UIKit

/// Messages/Telegram-style circular avatar: monogram, emoji, or cached image.
struct AgentAvatarView: View {
    let title: String
    let seed: UUID
    var hasUnread: Bool = false
    var size: CGFloat = 52
    var kind: AgentAvatarKind = .none
    var emoji: String? = nil
    var localImagePath: String? = nil

    init(
        title: String,
        seed: UUID,
        hasUnread: Bool = false,
        size: CGFloat = 52,
        kind: AgentAvatarKind = .none,
        emoji: String? = nil,
        localImagePath: String? = nil
    ) {
        self.title = title
        self.seed = seed
        self.hasUnread = hasUnread
        self.size = size
        self.kind = kind
        self.emoji = emoji
        self.localImagePath = localImagePath
    }

    init(project: RemoteProject, hasUnread: Bool = false, size: CGFloat = 52) {
        self.title = project.displayTitle
        self.seed = project.id
        self.hasUnread = hasUnread
        self.size = size
        self.kind = project.avatarKind
        self.emoji = project.avatarEmoji
        self.localImagePath = project.avatarLocalImagePath
    }

    private var monogram: String {
        Self.monogram(from: title)
    }

    private var tint: Color {
        Self.tint(for: seed)
    }

    var body: some View {
        ZStack {
            content
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if hasUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 2)
                    )
                    .offset(x: 1, y: 1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .emoji:
            if let emoji, !emoji.isEmpty {
                Circle()
                    .fill(Color(.secondarySystemFill))
                Text(emoji)
                    .font(.system(size: size * 0.52))
                    .minimumScaleFactor(0.5)
            } else {
                monogramContent
            }
        case .image:
            if let localImagePath,
               let uiImage = UIImage(contentsOfFile: localImagePath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                monogramContent
            }
        case .none:
            monogramContent
        }
    }

    private var monogramContent: some View {
        ZStack {
            Circle()
                .fill(tint.gradient)
            Text(monogram)
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    // MARK: - Pure helpers

    static func monogram(from title: String) -> String {
        let parts = title
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let letters = parts.compactMap { $0.first.map { String($0).uppercased() } }
        if letters.isEmpty {
            return String(title.prefix(1)).uppercased().isEmpty ? "?" : String(title.prefix(1)).uppercased()
        }
        return letters.joined()
    }

    static func tint(for seed: UUID) -> Color {
        // Stable palette (Telegram-like) keyed by UUID bytes.
        let palette: [Color] = [
            Color(red: 0.20, green: 0.60, blue: 0.86),
            Color(red: 0.35, green: 0.78, blue: 0.48),
            Color(red: 0.95, green: 0.55, blue: 0.20),
            Color(red: 0.91, green: 0.30, blue: 0.40),
            Color(red: 0.55, green: 0.40, blue: 0.90),
            Color(red: 0.20, green: 0.72, blue: 0.72),
            Color(red: 0.96, green: 0.70, blue: 0.20),
            Color(red: 0.40, green: 0.50, blue: 0.95),
        ]
        var hasher = Hasher()
        hasher.combine(seed)
        let index = abs(hasher.finalize()) % palette.count
        return palette[index]
    }
}

#Preview {
    HStack(spacing: 16) {
        AgentAvatarView(title: "Ops Bot", seed: UUID(), hasUnread: true)
        AgentAvatarView(title: "mobile-code", seed: UUID(), kind: .emoji, emoji: "🚀")
        AgentAvatarView(title: "A", seed: UUID())
    }
    .padding()
}
