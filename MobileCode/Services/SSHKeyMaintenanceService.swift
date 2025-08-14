//
//  SSHKeyMaintenanceService.swift
//  CodeAgentsMobile
//
//  Purpose: Service for maintaining SSH keys, including generating missing public keys
//

import Foundation
import SwiftData
import Crypto

class SSHKeyMaintenanceService {
    static let shared = SSHKeyMaintenanceService()
    
    private init() {}
    
    /// Check all SSH keys and generate missing public keys
    @MainActor
    func generateMissingPublicKeys(in modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<SSHKey>()
        
        do {
            let sshKeys = try modelContext.fetch(descriptor)
            var keysUpdated = 0
            
            for sshKey in sshKeys {
                // Check if public key is missing or is a placeholder
                if sshKey.publicKey.isEmpty || sshKey.publicKey.contains("PLACEHOLDER") {
                    print("Found SSH key '\(sshKey.name)' with missing/placeholder public key")
                    
                    // Try to generate the public key
                    if let publicKey = await generatePublicKey(for: sshKey) {
                        sshKey.publicKey = publicKey
                        keysUpdated += 1
                        print("✅ Generated public key for '\(sshKey.name)'")
                    } else {
                        print("❌ Failed to generate public key for '\(sshKey.name)'")
                    }
                }
            }
            
            // Save changes if any keys were updated
            if keysUpdated > 0 {
                try modelContext.save()
                print("✅ Updated \(keysUpdated) SSH key(s) with generated public keys")
            } else {
                print("ℹ️ All SSH keys already have valid public keys")
            }
            
        } catch {
            print("Failed to fetch or update SSH keys: \(error)")
        }
    }
    
    /// Generate public key for a specific SSH key
    private func generatePublicKey(for sshKey: SSHKey) async -> String? {
        do {
            // Retrieve the private key from keychain
            let privateKeyData = try KeychainManager.shared.retrieveSSHKey(for: sshKey.id)
            guard !privateKeyData.isEmpty else {
                print("No private key found in keychain for '\(sshKey.name)'")
                return nil
            }
            
            // Check if we need a passphrase
            let passphrase = try? KeychainManager.shared.retrieveSSHKeyPassphrase(for: sshKey.id)
            
            // Use the SSHKeyFormatter to extract and format the public key
            return SSHKeyFormatter.extractPublicKey(
                from: privateKeyData,
                keyType: sshKey.keyType,
                passphrase: passphrase,
                name: sshKey.name
            )
            
        } catch {
            print("Failed to generate public key for '\(sshKey.name)': \(error)")
            return nil
        }
    }
}