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
    
    init(textBlock: TextBlock, textColor: Color = .primary) {
        self.textBlock = textBlock
        self.textColor = textColor
    }
    
    var body: some View {
        FullMarkdownTextView(text: textBlock.text, textColor: textColor)
    }
}