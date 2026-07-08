//
//  CodeAgentsUIRendererView.swift
//  CodeAgentsMobile
//
//  Purpose: Render codeagents_ui blocks as SwiftUI widgets.
//

import SwiftUI

struct CodeAgentsUIRendererView: View {
    let block: CodeAgentsUIBlock
    let project: RemoteProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = block.title, !title.isEmpty {
                Text(title)
                    .font(.headline)
            }

            ForEach(block.elements, id: \.id) { element in
                elementView(element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func elementView(_ element: CodeAgentsUIElement) -> some View {
        switch element {
        case .card(let card):
            CodeAgentsUICardView(card: card, project: project)
        case .markdown(let markdown):
            FullMarkdownTextView(text: markdown.text)
        case .image(let image):
            CodeAgentsUIImageView(image: image, project: project)
        case .gallery(let gallery):
            CodeAgentsUIGalleryView(gallery: gallery, project: project)
        case .video(let video):
            CodeAgentsUIVideoView(video: video, project: project)
        case .table(let table):
            CodeAgentsUITableView(table: table)
        case .chart(let chart):
            CodeAgentsUIChartView(chart: chart)
        }
    }
}
