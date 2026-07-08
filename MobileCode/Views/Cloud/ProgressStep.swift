//
//  ProgressStep.swift
//  CodeAgentsMobile
//
//  Compact step indicator used by cloud server provisioning progress UI.
//

import SwiftUI

struct ProgressStep: View {
    let title: String
    let isComplete: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isComplete ? .green : .gray.opacity(0.3))
                .font(.system(size: 20))
            
            Text(title)
                .font(.subheadline)
                .foregroundColor(isComplete ? .primary : .secondary)
            
            Spacer()
        }
    }
}
