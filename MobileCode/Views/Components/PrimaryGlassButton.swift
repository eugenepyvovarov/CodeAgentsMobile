//
//  PrimaryGlassButton.swift
//  CodeAgentsMobile
//
//  Purpose: Button style wrapper for Liquid Glass with fallback
//

import SwiftUI

struct PrimaryGlassButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action, label: label)
                .buttonStyle(.glassProminent)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    PrimaryGlassButton(action: {}) {
        Label("Primary", systemImage: "sparkles")
    }
}
