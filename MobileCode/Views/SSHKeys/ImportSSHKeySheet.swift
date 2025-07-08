//
//  ImportSSHKeySheet.swift
//  CodeAgentsMobile
//
//  Purpose: Sheet for importing SSH private keys
//  - Supports pasting key content or importing from Files
//  - Validates key format and detects key type
//  - Handles passphrase-protected keys
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportSSHKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var keyName = ""
    @State private var keyContent = ""
    @State private var passphrase = ""
    @State private var rememberPassphrase = false
    @State private var importMethod: ImportMethod = .paste
    @State private var showingFilePicker = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var detectedKeyType = ""
    @State private var isImporting = false
    
    enum ImportMethod: String, CaseIterable {
        case paste = "Paste"
        case file = "Import File"
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Key Information") {
                    TextField("Key Name", text: $keyName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    if !detectedKeyType.isEmpty {
                        HStack {
                            Text("Type:")
                            Spacer()
                            Text(detectedKeyType)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("Import Method") {
                    Picker("Method", selection: $importMethod) {
                        ForEach(ImportMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    if importMethod == .paste {
                        TextEditor(text: $keyContent)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 200)
                            .onChange(of: keyContent) { _, newValue in
                                detectKeyType(from: newValue)
                            }
                            .overlay(alignment: .topLeading) {
                                if keyContent.isEmpty {
                                    Text("Paste your private SSH key here...")
                                        .foregroundColor(.secondary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                    } else {
                        Button(action: { showingFilePicker = true }) {
                            Label("Select Key File", systemImage: "doc.badge.plus")
                        }
                    }
                }
                
                Section {
                    SecureField("Passphrase (if encrypted)", text: $passphrase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    Toggle("Remember passphrase", isOn: $rememberPassphrase)
                    
                    if rememberPassphrase {
                        Label("The passphrase will be stored securely in your iCloud Keychain and synced across your devices.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("If your key is encrypted, enter the passphrase. Leave empty for unencrypted keys.")
                        .font(.caption)
                }
            }
            .navigationTitle("Import SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task {
                            await importKey()
                        }
                    }
                    .disabled(keyName.isEmpty || (importMethod == .paste && keyContent.isEmpty) || isImporting)
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.text, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Import Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .disabled(isImporting)
            .overlay {
                if isImporting {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Importing...")
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                        .shadow(radius: 5)
                }
            }
        }
    }
    
    private func detectKeyType(from content: String) {
        let data = content.data(using: .utf8) ?? Data()
        detectedKeyType = PrivateKeyAuthenticationDelegate.detectKeyType(from: data) ?? ""
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            do {
                let data = try Data(contentsOf: url)
                if let content = String(data: data, encoding: .utf8) {
                    keyContent = content
                    detectKeyType(from: content)
                    
                    // Try to extract key name from filename
                    if keyName.isEmpty {
                        let filename = url.deletingPathExtension().lastPathComponent
                        keyName = filename
                    }
                } else {
                    errorMessage = "Unable to read key file. Please ensure it's a text file."
                    showingError = true
                }
            } catch {
                errorMessage = "Failed to read file: \(error.localizedDescription)"
                showingError = true
            }
        case .failure(let error):
            errorMessage = "Failed to select file: \(error.localizedDescription)"
            showingError = true
        }
    }
    
    @MainActor
    private func importKey() async {
        isImporting = true
        defer { isImporting = false }
        
        // Validate key content
        guard let keyData = keyContent.data(using: .utf8) else {
            errorMessage = "Invalid key content"
            showingError = true
            return
        }
        
        // Validate the key using SSHKeyParser
        // Validate key data
        
        let validation = SSHKeyParserV2.validate(keyData: keyData)
        // Check validation result
        
        if !validation.isValid {
            errorMessage = validation.error ?? "Invalid key format"
            showingError = true
            return
        }
        
        // Parse the key to verify it works and get the actual type
        let keyType: String
        do {
            // Parse the SSH key
            let parseResult = try SSHKeyParserV2.parse(keyData: keyData, passphrase: passphrase.isEmpty ? nil : passphrase)
            keyType = parseResult.keyType
            // Successfully parsed key
        } catch {
            // Parse failed
            errorMessage = error.localizedDescription
            showingError = true
            return
        }
        
        // Create SSH key model
        let sshKey = SSHKey(
            name: keyName,
            keyType: keyType,
            privateKeyIdentifier: UUID().uuidString
        )
        
        do {
            // Store the private key in Keychain
            try KeychainManager.shared.storeSSHKey(keyData, for: sshKey.id)
            
            // Store passphrase if provided and remember is enabled
            if !passphrase.isEmpty && rememberPassphrase {
                try KeychainManager.shared.storeSSHKeyPassphrase(passphrase, for: sshKey.id)
            }
            
            // Save the SSH key model
            modelContext.insert(sshKey)
            try modelContext.save()
            
            dismiss()
        } catch {
            errorMessage = "Failed to import key: \(error.localizedDescription)"
            showingError = true
            
            // Clean up on failure
            try? KeychainManager.shared.deleteSSHKey(for: sshKey.id)
        }
    }
}

#Preview {
    ImportSSHKeySheet()
        .modelContainer(for: [SSHKey.self], inMemory: true)
}