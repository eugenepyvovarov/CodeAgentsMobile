//
//  MissingCreatedServerSheet.swift
//  CodeAgentsMobile
//
//  Fallback sheet when a newly created server record is no longer available.
//

import SwiftUI

struct MissingCreatedServerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Server Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The new server record is no longer available.")
            } actions: {
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Add Agent")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
