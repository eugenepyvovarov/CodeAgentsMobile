//
//  TerminalView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Terminal interface placeholder
//  TODO: Implement when TerminalViewModel is ready
//

import SwiftUI

struct TerminalView: View {
    @State private var viewModel = TerminalViewModel()
    @State private var showingSettings = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                Image(systemName: "terminal")
                    .font(.system(size: 80))
                    .foregroundColor(.secondary)
                
                Text(viewModel.placeholderMessage)
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.outputLines, id: \.self) { line in
                        Text(line)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fontFamily(.monospaced)
                    }
                }
                .padding()
                .frame(maxWidth: 350)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                
                Spacer()
                Spacer()
            }
            .padding()
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
    }
}

#Preview {
    TerminalView()
}