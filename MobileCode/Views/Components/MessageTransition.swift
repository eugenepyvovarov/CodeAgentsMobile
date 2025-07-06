//
//  MessageTransition.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-06.
//

import SwiftUI

// MARK: - Message Appear Animation
struct MessageAppearModifier: ViewModifier {
    @State private var isVisible = false
    
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(isVisible ? 1 : 0.8)
            .offset(y: isVisible ? 0 : 20)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    isVisible = true
                }
            }
    }
}

// MARK: - Typing Indicator
struct TypingIndicator: View {
    @State private var dotOpacity: [Double] = [0.2, 0.2, 0.2]
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(dotOpacity[index])
            }
        }
        .onAppear {
            animateDots()
        }
    }
    
    private func animateDots() {
        for index in 0..<3 {
            withAnimation(.easeInOut(duration: 0.6)
                .repeatForever()
                .delay(Double(index) * 0.2)) {
                dotOpacity[index] = 1.0
            }
        }
    }
}

// MARK: - Extensions
extension View {
    func messageAppear() -> some View {
        modifier(MessageAppearModifier())
    }
}