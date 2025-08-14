//
//  AddSSHKeySheet.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import SwiftUI
import SwiftData

struct AddSSHKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOption: KeyOption = .import
    @State private var showingImportSheet = false
    @State private var showingGenerateSheet = false
    
    enum KeyOption: String, CaseIterable {
        case `import` = "Import Existing Key"
        case generate = "Generate New Key"
        
        var icon: String {
            switch self {
            case .import: return "square.and.arrow.down"
            case .generate: return "key.fill"
            }
        }
        
        var description: String {
            switch self {
            case .import: return "Import an existing SSH private key from a file or paste it directly"
            case .generate: return "Generate a new Ed25519 SSH key pair"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("How would you like to add an SSH key?")
                    .font(.headline)
                    .padding(.top, 20)
                
                VStack(spacing: 16) {
                    ForEach(KeyOption.allCases, id: \.self) { option in
                        Button(action: {
                            selectedOption = option
                            if option == .import {
                                showingImportSheet = true
                            } else {
                                showingGenerateSheet = true
                            }
                        }) {
                            HStack {
                                Image(systemName: option.icon)
                                    .font(.title2)
                                    .frame(width: 40)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.rawValue)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    Text(option.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("Add SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingImportSheet, onDismiss: {
                // When import sheet dismisses, also dismiss this sheet
                // This ensures we return directly to settings
                dismiss()
            }) {
                ImportSSHKeySheet()
            }
            .sheet(isPresented: $showingGenerateSheet, onDismiss: {
                // When generate sheet dismisses, also dismiss this sheet
                // This ensures we return directly to settings
                dismiss()
            }) {
                GenerateSSHKeySheet()
            }
        }
    }
}

#Preview {
    AddSSHKeySheet()
        .modelContainer(for: [SSHKey.self], inMemory: true)
}