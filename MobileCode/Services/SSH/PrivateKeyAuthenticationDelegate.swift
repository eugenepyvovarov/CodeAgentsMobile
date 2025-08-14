//
//  PrivateKeyAuthenticationDelegate.swift
//  CodeAgentsMobile
//
//  Purpose: SSH private key authentication delegate for SwiftNIO SSH
//  - Supports Ed25519, P256, P384, P521 key types
//  - Handles passphrase-protected keys
//  - Integrates with KeychainManager for secure key storage
//

import Foundation
import NIO
@preconcurrency import NIOSSH

/// Private key authentication delegate for SSH connections
final class PrivateKeyAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let keyId: UUID
    private let passphraseProvider: () async throws -> String?
    
    /// Initialize with SSH key information
    /// - Parameters:
    ///   - username: SSH username
    ///   - keyId: UUID of the SSH key stored in Keychain
    ///   - passphraseProvider: Closure to provide passphrase if needed
    init(username: String, keyId: UUID, passphraseProvider: @escaping () async throws -> String? = { nil }) {
        self.username = username
        self.keyId = keyId
        self.passphraseProvider = passphraseProvider
    }
    
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Check if public key authentication is available
        guard availableMethods.contains(.publicKey) else {
            SSHLogger.log("Public key authentication not available", level: .warning)
            nextChallengePromise.succeed(nil)
            return
        }
        
        // Load the private key from Keychain
        Task {
            do {
                // Retrieve the private key data from keychain
                let privateKeyData = try KeychainManager.shared.retrieveSSHKey(for: keyId)
                
                // Check if we have a stored passphrase
                var passphrase = KeychainManager.shared.retrieveSSHKeyPassphrase(for: keyId)
                
                // If no stored passphrase, ask the provider
                if passphrase == nil {
                    passphrase = try await passphraseProvider()
                }
                
                // Parse the private key using SSHKeyParser
                let parseResult = try SSHKeyParserV2.parse(keyData: privateKeyData, passphrase: passphrase)
                let privateKey = parseResult.privateKey
                
                // Create the authentication offer
                let offer = NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: privateKey))
                )
                
                nextChallengePromise.succeed(offer)
                
            } catch {
                SSHLogger.log("Failed to load private key: \(error)", level: .error)
                nextChallengePromise.succeed(nil)
            }
        }
    }
    
}

/// Extension to detect SSH key type from key data
extension PrivateKeyAuthenticationDelegate {
    /// Detect the type of SSH key from its content
    /// - Parameter data: Private key data
    /// - Returns: Key type string (e.g., "Ed25519", "P256", etc.)
    static func detectKeyType(from data: Data) -> String? {
        // Use SSHKeyParser's detection
        return SSHKeyParserV2.detectKeyType(from: data)
    }
    
    /// Validate if a key type is supported
    /// - Parameter keyType: String
    /// - Returns: True if supported
    static func isKeyTypeSupported(_ keyType: String) -> Bool {
        let supportedTypes = ["Ed25519", "P256", "P384", "P521", "ECDSA"]
        return supportedTypes.contains(keyType)
    }
}