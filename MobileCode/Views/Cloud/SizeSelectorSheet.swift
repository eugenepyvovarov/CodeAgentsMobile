//
//  SizeSelectorSheet.swift
//  CodeAgentsMobile
//
//  Size picker presented from CreateCloudServerView.
//

import SwiftUI

struct SizeSelectorSheet: View {
    let availableSizes: [(id: String, name: String, description: String)]
    @Binding var selectedSize: String
    let providerType: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(availableSizes, id: \.id) { size in
                    Button(action: {
                        selectedSize = size.id
                        dismiss()
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(size.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                // Parse and format the description
                                if let details = parseDescription(size.description) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 12) {
                                            Label(details.cpu, systemImage: "cpu")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Label(details.ram, systemImage: "memorychip")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        HStack(spacing: 12) {
                                            Label(details.storage, systemImage: "internaldrive")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(details.price)
                                                .font(.caption)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                } else {
                                    Text(size.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            
                            Spacer()
                            
                            if selectedSize == size.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                                    .font(.title2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Select Server Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func parseDescription(_ description: String) -> (cpu: String, ram: String, storage: String, price: String)? {
        // Parse description like "2 vCPUs • 4GB RAM • 80GB SSD • $24/mo"
        let components = description.split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        
        if components.count >= 4 {
            return (
                cpu: String(components[0]),
                ram: String(components[1]),
                storage: String(components[2]),
                price: String(components[3])
            )
        }
        
        return nil
    }
}
