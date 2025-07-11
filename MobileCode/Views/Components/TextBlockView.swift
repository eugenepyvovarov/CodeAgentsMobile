//
//  TextBlockView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import SwiftUI

struct TextBlockView: View {
    let textBlock: TextBlock
    let textColor: Color
    let isStreaming: Bool
    
    init(textBlock: TextBlock, textColor: Color = .primary, isStreaming: Bool = false) {
        self.textBlock = textBlock
        self.textColor = textColor
        self.isStreaming = isStreaming
    }
    
    var body: some View {
        // No cursor animation per user preference
        FullMarkdownTextView(text: textBlock.text, textColor: textColor)
    }
}