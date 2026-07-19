//
//  AuthorSupportPromptSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Friendly recurring prompt to follow or support the open-source author.
//

import SwiftUI

struct AuthorSupportPromptSheet: View {
    let onNeverShowAgain: () -> Void
    let onMaybeLater: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    followAction
                    sponsorshipActions
                    footerActions
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Support CodeAgents")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.14))
                    .frame(width: 76, height: 76)

                Image(systemName: "heart.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }

            Text("Thanks for using CodeAgents")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(
                "CodeAgents is independently built and shared as open source. "
                    + "If it’s useful, following the author helps more people discover it. "
                    + "You can also support ongoing development."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Text("No pressure—thanks for being here.")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
        }
    }

    private var followAction: some View {
        Button {
            openURL(AuthorSupportLinks.x)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                Text("Follow @selfhosted_ai on X")
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint("Opens the author’s X profile and keeps this sheet open")
    }

    private var sponsorshipActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Support open-source development")
                .font(.headline)

            SupportDestinationButton(
                title: "Sponsor on GitHub",
                subtitle: "Support ongoing development",
                systemImage: "chevron.left.forwardslash.chevron.right"
            ) {
                openURL(AuthorSupportLinks.githubSponsors)
            }

            SupportDestinationButton(
                title: "Support on Patreon",
                subtitle: "Become a recurring supporter",
                systemImage: "heart.circle.fill"
            ) {
                openURL(AuthorSupportLinks.patreon)
            }

            SupportDestinationButton(
                title: "Buy Me a Coffee",
                subtitle: "Send a one-time thank-you",
                systemImage: "cup.and.saucer.fill"
            ) {
                openURL(AuthorSupportLinks.buyMeACoffee)
            }
        }
    }

    private var footerActions: some View {
        VStack(spacing: 14) {
            Button(action: onNeverShowAgain) {
                Label("Don’t show this again", systemImage: "square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityHint("Permanently disables this support reminder")

            Button("Maybe later", action: onMaybeLater)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityHint("Closes this sheet and shows it again in fourteen days")
        }
    }
}

private struct SupportDestinationButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens an external sponsorship page and keeps this sheet open")
    }
}

enum AuthorSupportLinks {
    static let x = URL(string: "https://x.com/selfhosted_ai")!
    static let githubSponsors = URL(string: "https://github.com/sponsors/eugenepyvovarov")!
    static let patreon = URL(string: "https://patreon.com/selfhosted_ninja")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/selfhostedninja")!
}
