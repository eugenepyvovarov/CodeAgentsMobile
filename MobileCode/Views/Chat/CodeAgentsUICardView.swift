//
//  CodeAgentsUICardView.swift
//  CodeAgentsMobile
//
//  Purpose: Card widget renderer for codeagents_ui blocks
//

import SwiftUI

struct CodeAgentsUICardView: View {
    let card: CodeAgentsUICard
    let project: RemoteProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if !card.content.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(card.content, id: \.id) { element in
                        CodeAgentsUIRendererView(block: CodeAgentsUIBlock(title: nil, elements: [element]), project: project)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4).opacity(0.4), lineWidth: 0.5)
        )
    }
}
