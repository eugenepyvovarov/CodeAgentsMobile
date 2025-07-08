//
//  SSHKeyListView.swift
//  CodeAgentsMobile
//
//  Purpose: List view for managing SSH keys
//  - Shows all imported SSH keys with their types
//  - Displays usage count for each key
//  - Supports swipe to delete (only for unused keys)
//

import SwiftUI
import SwiftData

struct SSHKeyListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SSHKey.createdAt, order: .reverse) private var sshKeys: [SSHKey]
    @Query private var servers: [Server]
    
    @State private var showingImportSheet = false
    @State private var showingDeleteAlert = false
    @State private var keyToDelete: SSHKey?
    @State private var deleteError: String?
    
    var body: some View {
        NavigationStack {
            List {
                if sshKeys.isEmpty {
                    ContentUnavailableView {
                        Label("No SSH Keys", systemImage: "key.slash")
                    } description: {
                        Text("Import SSH keys to use for server authentication")
                    } actions: {
                        Button("Import Key") {
                            showingImportSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(sshKeys) { key in
                        SSHKeyRow(
                            sshKey: key,
                            usageCount: getUsageCount(for: key)
                        )
                    }
                    .onDelete(perform: deleteKeys)
                }
            }
            .navigationTitle("SSH Keys")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingImportSheet = true }) {
                        Label("Import", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportSSHKeySheet()
            }
            .alert("Cannot Delete Key", isPresented: .constant(deleteError != nil)) {
                Button("OK") {
                    deleteError = nil
                }
            } message: {
                if let error = deleteError {
                    Text(error)
                }
            }
        }
    }
    
    private func getUsageCount(for key: SSHKey) -> Int {
        servers.filter { $0.sshKeyId == key.id }.count
    }
    
    private func deleteKeys(at offsets: IndexSet) {
        for index in offsets {
            let key = sshKeys[index]
            let usageCount = getUsageCount(for: key)
            
            if usageCount > 0 {
                deleteError = "This key is used by \(usageCount) server\(usageCount > 1 ? "s" : ""). Remove it from all servers before deleting."
                return
            }
            
            // Delete from Keychain
            do {
                try KeychainManager.shared.deleteSSHKey(for: key.id)
            } catch {
                deleteError = "Failed to delete key from Keychain: \(error.localizedDescription)"
                return
            }
            
            // Delete from SwiftData
            modelContext.delete(key)
        }
        
        // Save changes
        do {
            try modelContext.save()
        } catch {
            deleteError = "Failed to save changes: \(error.localizedDescription)"
        }
    }
}

struct SSHKeyRow: View {
    let sshKey: SSHKey
    let usageCount: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sshKey.name)
                    .font(.headline)
                
                Spacer()
                
                Text(sshKey.keyType)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
            
            HStack {
                Image(systemName: "server.rack")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(usageText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(RelativeDateTimeFormatter().localizedString(for: sshKey.createdAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
    
    private var usageText: String {
        switch usageCount {
        case 0:
            return "Not used yet"
        case 1:
            return "Used by 1 server"
        default:
            return "Used by \(usageCount) servers"
        }
    }
}

#Preview {
    SSHKeyListView()
        .modelContainer(for: [SSHKey.self, Server.self], inMemory: true)
}