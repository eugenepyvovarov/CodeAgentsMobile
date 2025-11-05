import SwiftUI
import SwiftData

struct SSHKeySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedKeyID: UUID?
    @Query private var sshKeys: [SSHKey]
    
    let onAddKey: (() -> Void)?
    
    init(selectedKeyID: Binding<UUID?>, onAddKey: (() -> Void)? = nil) {
        self._selectedKeyID = selectedKeyID
        self.onAddKey = onAddKey
    }
    
    private var usableKeys: [SSHKey] {
        sshKeys.filter {
            (try? KeychainManager.shared.retrieveSSHKey(for: $0.id)) != nil
        }
    }
    
    var body: some View {
        List {
            if usableKeys.isEmpty {
                ContentUnavailableView {
                    Label("No SSH Keys", systemImage: "key.slash")
                } description: {
                    Text("Import or generate a new SSH key with a stored private key.")
                }
            } else {
                ForEach(usableKeys) { key in
                    Button {
                        selectedKeyID = key.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key.name)
                                Text(key.keyType)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedKeyID == key.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Select SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onAddKey = onAddKey {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onAddKey()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}
