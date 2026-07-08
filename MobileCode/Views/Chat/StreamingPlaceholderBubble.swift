//
//  StreamingPlaceholderBubble.swift
//  CodeAgentsMobile
//
//  Placeholder bubble shown while an assistant/user message is streaming with no content yet.
//

import SwiftUI

struct StreamingPlaceholderBubble: View {
    let isUser: Bool

    var body: some View {
        let bubbleBackground = isUser ? Color.accentColor : Color(.systemGray6)
        let bubbleTextColor: Color = isUser ? .white : .secondary

        HStack {
            if isUser {
                Spacer()
            }

            Text("...")
                .font(.body.weight(.semibold))
                .foregroundColor(bubbleTextColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: UIScreen.main.bounds.width * 0.5, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer()
            }
        }
    }
}
