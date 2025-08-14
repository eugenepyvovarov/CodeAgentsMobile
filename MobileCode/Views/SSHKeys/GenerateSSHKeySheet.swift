//
//  GenerateSSHKeySheet.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import SwiftUI
import SwiftData
import Crypto

struct GenerateSSHKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var keyName = ""
    @State private var includePassphrase = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var isGenerating = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var generatedKeyData: (privateKey: String, publicKey: String)?
    @State private var showSaveOptions = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Key Name", text: $keyName)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                }
                
                Section {
                    Toggle("Add Passphrase", isOn: $includePassphrase)
                    
                    if includePassphrase {
                        SecureField("Passphrase", text: $passphrase)
                            .autocapitalization(.none)
                        
                        SecureField("Confirm Passphrase", text: $confirmPassphrase)
                            .autocapitalization(.none)
                        
                        if !passphrase.isEmpty && !confirmPassphrase.isEmpty && passphrase != confirmPassphrase {
                            Label("Passphrases don't match", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                .animation(.default, value: includePassphrase)
            }
            .navigationTitle("Generate SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        generateKey()
                    }
                    .disabled(!isFormValid || isGenerating)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
            .disabled(isGenerating)
            .overlay {
                if isGenerating {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Generating Key...")
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                        .shadow(radius: 5)
                }
            }
            .confirmationDialog("SSH Key Generated", isPresented: $showSaveOptions) {
                Button("Copy Public Key") {
                    if let data = generatedKeyData {
                        UIPasteboard.general.string = data.publicKey
                    }
                    dismiss()
                }
                Button("Export to Files") {
                    exportToFiles()
                }
                Button("Done") {
                    dismiss()
                }
            } message: {
                Text("Your SSH key has been generated and saved. Would you like to export it?")
            }
        }
    }
    
    private func exportToFiles() {
        guard let keyData = generatedKeyData else {
            dismiss()
            return
        }
        
        // Create temporary files
        let tempDir = FileManager.default.temporaryDirectory
        let privateKeyURL = tempDir.appendingPathComponent("\(keyName)")
        let publicKeyURL = tempDir.appendingPathComponent("\(keyName).pub")
        
        do {
            // Write private key (already in PEM format)
            try keyData.privateKey.write(to: privateKeyURL, atomically: true, encoding: .utf8)
            
            // Write public key
            try keyData.publicKey.write(to: publicKeyURL, atomically: true, encoding: .utf8)
            
            // Create activity controller
            let activityController = UIActivityViewController(
                activityItems: [privateKeyURL, publicKeyURL],
                applicationActivities: nil
            )
            
            // Present from the top view controller
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootViewController = window.rootViewController {
                var topController = rootViewController
                while let presented = topController.presentedViewController {
                    topController = presented
                }
                
                activityController.completionWithItemsHandler = { _, _, _, _ in
                    // Clean up temp files and dismiss
                    try? FileManager.default.removeItem(at: privateKeyURL)
                    try? FileManager.default.removeItem(at: publicKeyURL)
                    self.dismiss()
                }
                
                topController.present(activityController, animated: true)
            } else {
                dismiss()
            }
        } catch {
            errorMessage = "Failed to export keys: \(error.localizedDescription)"
            showError = true
            dismiss()
        }
    }
    
    private func formatEd25519PrivateKey(_ keyData: Data) -> String {
        // Create a simplified OpenSSH private key format
        // Note: This is a simplified version. A full implementation would need proper OpenSSH format
        var result = "-----BEGIN OPENSSH PRIVATE KEY-----\n"
        
        // Create OpenSSH format data (simplified)
        var data = Data()
        
        // Magic header
        data.append("openssh-key-v1\0".data(using: .utf8)!)
        
        // Add cipher, kdf, kdf options (none for unencrypted)
        data.append(Data([0, 0, 0, 4])) // length
        data.append("none".data(using: .utf8)!)
        data.append(Data([0, 0, 0, 4])) // length
        data.append("none".data(using: .utf8)!)
        data.append(Data([0, 0, 0, 0])) // empty kdf options
        
        // Number of keys
        data.append(Data([0, 0, 0, 1]))
        
        // Public key section
        let publicKeyData = keyData.suffix(32) // Ed25519 public key is last 32 bytes
        var pubKeySection = Data()
        pubKeySection.append(Data([0, 0, 0, 11])) // length of "ssh-ed25519"
        pubKeySection.append("ssh-ed25519".data(using: .utf8)!)
        pubKeySection.append(Data([0, 0, 0, 32])) // length of public key
        pubKeySection.append(publicKeyData)
        
        // Add public key section length and data
        var pubKeySectionLength = UInt32(pubKeySection.count).bigEndian
        data.append(Data(bytes: &pubKeySectionLength, count: 4))
        data.append(pubKeySection)
        
        // Private key section (simplified)
        var privKeySection = Data()
        privKeySection.append(contentsOf: [0x64, 0x64, 0x64, 0x64]) // check bytes
        privKeySection.append(pubKeySection) // repeat public key section
        privKeySection.append(Data([0, 0, 0, 64])) // length of private key (32 private + 32 public)
        privKeySection.append(keyData) // full key data
        privKeySection.append(Data([0, 0, 0, 0])) // comment length
        
        // Pad to block size (8 bytes)
        let padding = (8 - (privKeySection.count % 8)) % 8
        for i in 1...padding {
            privKeySection.append(UInt8(i))
        }
        
        // Add private key section
        var privKeySectionLength = UInt32(privKeySection.count).bigEndian
        data.append(Data(bytes: &privKeySectionLength, count: 4))
        data.append(privKeySection)
        
        // Base64 encode
        let base64String = data.base64EncodedString()
        
        // Add line breaks every 70 characters (OpenSSH standard)
        var formattedBase64 = ""
        var index = base64String.startIndex
        while index < base64String.endIndex {
            let endIndex = base64String.index(index, offsetBy: 70, limitedBy: base64String.endIndex) ?? base64String.endIndex
            formattedBase64 += base64String[index..<endIndex]
            formattedBase64 += "\n"
            index = endIndex
        }
        
        result += formattedBase64
        result += "-----END OPENSSH PRIVATE KEY-----\n"
        
        return result
    }
    
    private var isFormValid: Bool {
        guard !keyName.isEmpty else { return false }
        
        if includePassphrase {
            return !passphrase.isEmpty && passphrase == confirmPassphrase
        }
        
        return true
    }
    
    private func generateKey() {
        isGenerating = true
        
        Task {
            await generateKeyAsync()
        }
    }
    
    @MainActor
    private func generateKeyAsync() async {
        defer { isGenerating = false }
        
        do {
            // Always generate Ed25519 key
            let (privateKeyData, publicKeyString) = try generateEd25519KeyPair()
            
            // Create SSH key model
            let sshKey = SSHKey(
                name: keyName,
                keyType: "Ed25519",
                privateKeyIdentifier: UUID().uuidString
            )
            
            // Store the public key
            sshKey.publicKey = publicKeyString
            
            // Store the raw private key data in Keychain (needed for SSH connections)
            try KeychainManager.shared.storeSSHKey(privateKeyData, for: sshKey.id)
            
            // Store passphrase if provided
            if includePassphrase && !passphrase.isEmpty {
                try KeychainManager.shared.storeSSHKeyPassphrase(passphrase, for: sshKey.id)
            }
            
            // Save the SSH key model
            modelContext.insert(sshKey)
            try modelContext.save()
            
            // Store generated key data for export (format for display)
            let privateKeyPEM = formatEd25519PrivateKey(privateKeyData)
            generatedKeyData = (privateKeyPEM, publicKeyString)
            
            // Show save options
            showSaveOptions = true
        } catch {
            errorMessage = "Failed to generate key: \(error.localizedDescription)"
            showError = true
        }
    }
    
    private func generateEd25519KeyPair() throws -> (privateKey: Data, publicKey: String) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Format public key in OpenSSH format using the formatter
        let publicKeyString = SSHKeyFormatter.formatEd25519PublicKey(publicKey.rawRepresentation, name: keyName)
        
        // For Ed25519, combine private key (32 bytes) and public key (32 bytes) for storage
        // This allows us to reconstruct the full key pair later for export
        var fullKeyData = Data()
        fullKeyData.append(privateKey.rawRepresentation) // 32 bytes private
        fullKeyData.append(publicKey.rawRepresentation)  // 32 bytes public
        
        return (fullKeyData, publicKeyString)
    }
}

enum SSHKeyGenerationError: LocalizedError {
    case unsupportedKeyType
    
    var errorDescription: String? {
        switch self {
        case .unsupportedKeyType:
            return "Unsupported key type"
        }
    }
}

#Preview {
    GenerateSSHKeySheet()
        .modelContainer(for: [SSHKey.self], inMemory: true)
}