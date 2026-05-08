//
//  KeychainManager.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Secure storage for credentials using iOS Keychain
//  - Stores server passwords and SSH keys
//  - Supports biometric authentication
//  - Encrypts sensitive data
//

import Foundation
import Security

/// Manages secure storage of credentials in iOS Keychain
class KeychainManager {
    // MARK: - Singleton
    
    static let shared = KeychainManager()
    
    // MARK: - Properties
    
    private let serviceName = "com.claudecode.mobile"
    
    // MARK: - Error Types
    
    enum KeychainError: LocalizedError {
        case itemNotFound
        case invalidData
        case unknown(OSStatus)
        
        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Item not found in keychain"
            case .invalidData:
                return "Invalid data format"
            case .unknown(let status):
                return "Keychain error: \(status)"
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Store a password for a server
    /// - Parameters:
    ///   - password: The password to store
    ///   - serverId: Unique identifier for the server
    func storePassword(_ password: String, for serverId: UUID) throws {
        let key = passwordKey(for: serverId)
        let data = password.data(using: .utf8)!
        
        try store(data: data, for: key)
    }
    
    /// Retrieve a password for a server
    /// - Parameter serverId: Server identifier
    /// - Returns: The stored password
    func retrievePassword(for serverId: UUID) throws -> String {
        let key = passwordKey(for: serverId)
        let data = try retrieve(for: key)
        
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        
        return password
    }
    
    
    /// Delete password for a server
    /// - Parameter serverId: Server identifier
    func deletePassword(for serverId: UUID) throws {
        let passwordKey = passwordKey(for: serverId)
        try delete(for: passwordKey)
    }
    
    /// Store API key (for Claude)
    /// - Parameter apiKey: The API key to store
    func storeAPIKey(_ apiKey: String) throws {
        try storeAPIKey(apiKey, provider: .anthropic)
    }

    /// Store API key for a Claude provider.
    func storeAPIKey(_ apiKey: String, provider: ClaudeModelProvider) throws {
        let data = apiKey.data(using: .utf8)!
        try store(data: data, for: providerAPIKeyKey(for: provider))
    }
    
    /// Retrieve API key
    /// - Returns: The stored API key
    func retrieveAPIKey() throws -> String {
        try retrieveAPIKey(provider: .anthropic)
    }

    /// Retrieve API key for a Claude provider.
    func retrieveAPIKey(provider: ClaudeModelProvider) throws -> String {
        let data = try retrieve(for: providerAPIKeyKey(for: provider))

        guard let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return apiKey
    }
    
    /// Delete API key
    func deleteAPIKey() throws {
        try deleteAPIKey(provider: .anthropic)
    }

    /// Delete API key for a Claude provider.
    func deleteAPIKey(provider: ClaudeModelProvider) throws {
        try delete(for: providerAPIKeyKey(for: provider))
    }
    
    /// Check if API key exists
    /// - Returns: True if API key is stored
    func hasAPIKey() -> Bool {
        hasAPIKey(provider: .anthropic)
    }

    /// Check if API key exists for a Claude provider.
    func hasAPIKey(provider: ClaudeModelProvider) -> Bool {
        do {
            _ = try retrieveAPIKey(provider: provider)
            return true
        } catch {
            return false
        }
    }

    /// Store an OpenCode provider API key under the runtime-specific namespace.
    func storeOpenCodeAPIKey(_ apiKey: String, providerID: String) throws {
        let data = apiKey.data(using: .utf8)!
        try store(data: data, for: Self.openCodeAPIKeyAccount(for: providerID))
    }

    /// Store an OpenCode provider API key scoped to a specific server override.
    func storeOpenCodeAPIKey(_ apiKey: String, providerID: String, serverID: UUID) throws {
        let data = apiKey.data(using: .utf8)!
        try store(data: data, for: Self.openCodeAPIKeyAccount(for: providerID, serverID: serverID))
    }

    /// Retrieve an OpenCode provider API key from the runtime-specific namespace.
    func retrieveOpenCodeAPIKey(providerID: String) throws -> String {
        let data = try retrieve(for: Self.openCodeAPIKeyAccount(for: providerID))
        guard let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return apiKey
    }

    /// Retrieve a server-scoped OpenCode provider API key, falling back to the global key.
    func retrieveOpenCodeAPIKey(providerID: String, serverID: UUID) throws -> String {
        do {
            let data = try retrieve(for: Self.openCodeAPIKeyAccount(for: providerID, serverID: serverID))
            guard let apiKey = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return apiKey
        } catch KeychainError.itemNotFound {
            return try retrieveOpenCodeAPIKey(providerID: providerID)
        }
    }

    /// Delete an OpenCode provider API key from the runtime-specific namespace.
    func deleteOpenCodeAPIKey(providerID: String) throws {
        try delete(for: Self.openCodeAPIKeyAccount(for: providerID))
    }

    /// Delete a server-scoped OpenCode provider API key.
    func deleteOpenCodeAPIKey(providerID: String, serverID: UUID) throws {
        try delete(for: Self.openCodeAPIKeyAccount(for: providerID, serverID: serverID))
    }

    /// Check if an OpenCode provider API key exists in the runtime-specific namespace.
    func hasOpenCodeAPIKey(providerID: String) -> Bool {
        do {
            _ = try retrieveOpenCodeAPIKey(providerID: providerID)
            return true
        } catch {
            return false
        }
    }

    /// Check if a server-scoped or global OpenCode provider API key exists.
    func hasOpenCodeAPIKey(providerID: String, serverID: UUID) -> Bool {
        do {
            _ = try retrieveOpenCodeAPIKey(providerID: providerID, serverID: serverID)
            return true
        } catch {
            return false
        }
    }

    /// Store OpenCode server basic-auth credentials for a server.
    func storeOpenCodeServerCredentials(username: String, password: String, for serverId: UUID) throws {
        let sanitizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        try storeOpenCodeServerUsername(sanitizedUsername.isEmpty ? OpenCodeServerProvisioning.username : sanitizedUsername, for: serverId)
        try storeOpenCodeServerPassword(password, for: serverId)
    }

    /// Store an OpenCode server username for a server.
    func storeOpenCodeServerUsername(_ username: String, for serverId: UUID) throws {
        let data = username.data(using: .utf8)!
        try store(data: data, for: Self.openCodeServerUsernameAccount(for: serverId))
    }

    /// Retrieve the OpenCode server username for a server, defaulting to the managed username.
    func retrieveOpenCodeServerUsername(for serverId: UUID) throws -> String {
        do {
            let data = try retrieve(for: Self.openCodeServerUsernameAccount(for: serverId))
            guard let username = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? OpenCodeServerProvisioning.username : trimmed
        } catch KeychainError.itemNotFound {
            return OpenCodeServerProvisioning.username
        }
    }

    /// Store a generated or manually entered OpenCode server password for a server.
    func storeOpenCodeServerPassword(_ password: String, for serverId: UUID) throws {
        let data = password.data(using: .utf8)!
        try store(data: data, for: Self.openCodeServerPasswordAccount(for: serverId))
    }

    /// Retrieve the generated OpenCode server password for a managed server.
    func retrieveOpenCodeServerPassword(for serverId: UUID) throws -> String {
        let data = try retrieve(for: Self.openCodeServerPasswordAccount(for: serverId))
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return password
    }

    /// Delete OpenCode server basic-auth credentials for a server.
    func deleteOpenCodeServerCredentials(for serverId: UUID) throws {
        try? delete(for: Self.openCodeServerUsernameAccount(for: serverId))
        try deleteOpenCodeServerPassword(for: serverId)
    }

    /// Delete the generated or manually entered OpenCode server password for a server.
    func deleteOpenCodeServerPassword(for serverId: UUID) throws {
        try delete(for: Self.openCodeServerPasswordAccount(for: serverId))
    }

    /// Check if an OpenCode server password exists for a managed server.
    func hasOpenCodeServerPassword(for serverId: UUID) -> Bool {
        do {
            _ = try retrieveOpenCodeServerPassword(for: serverId)
            return true
        } catch {
            return false
        }
    }
    
    /// Store authentication token (for Claude Code OAuth)
    /// - Parameter token: The authentication token to store
    func storeAuthToken(_ token: String) throws {
        let data = token.data(using: .utf8)!
        try store(data: data, for: "claude_auth_token")
    }
    
    /// Retrieve authentication token
    /// - Returns: The stored authentication token
    func retrieveAuthToken() throws -> String {
        let data = try retrieve(for: "claude_auth_token")
        
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        
        return token
    }
    
    /// Delete authentication token
    func deleteAuthToken() throws {
        try delete(for: "claude_auth_token")
    }
    
    /// Check if authentication token exists
    /// - Returns: True if authentication token is stored
    func hasAuthToken() -> Bool {
        do {
            _ = try retrieveAuthToken()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Push Notifications

    /// Store the per-server push secret (CODEAGENTS_PUSH_SECRET)
    func storePushSecret(_ secret: String, for serverId: UUID) throws {
        let data = secret.data(using: .utf8)!
        try store(data: data, for: pushSecretKey(for: serverId))
    }

    /// Retrieve the per-server push secret (CODEAGENTS_PUSH_SECRET)
    func retrievePushSecret(for serverId: UUID) throws -> String {
        let data = try retrieve(for: pushSecretKey(for: serverId))
        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return secret
    }

    /// Delete the per-server push secret for this device
    func deletePushSecret(for serverId: UUID) throws {
        try delete(for: pushSecretKey(for: serverId))
    }

    /// Check if a push secret exists for a server
    func hasPushSecret(for serverId: UUID) -> Bool {
        do {
            _ = try retrievePushSecret(for: serverId)
            return true
        } catch {
            return false
        }
    }

    /// Stable identifier for this app install, used for device registration docs in Firestore.
    func getOrCreatePushInstallationId() throws -> String {
        if let existing = try? retrievePushInstallationId() {
            return existing
        }

        let fresh = UUID().uuidString.lowercased()
        try storePushInstallationId(fresh)
        return fresh
    }
    
    // MARK: - SSH Key Methods
    
    /// Store an SSH private key
    /// - Parameters:
    ///   - privateKey: The private key data
    ///   - keyId: Unique identifier for the SSH key
    func storeSSHKey(_ privateKey: Data, for keyId: UUID) throws {
        let key = sshKeyKey(for: keyId)
        try store(data: privateKey, for: key, syncToiCloud: true)
    }
    
    /// Retrieve an SSH private key
    /// - Parameter keyId: SSH key identifier
    /// - Returns: The stored private key data
    func retrieveSSHKey(for keyId: UUID) throws -> Data {
        let key = sshKeyKey(for: keyId)
        return try retrieve(for: key, syncToiCloud: true)
    }
    
    /// Delete SSH key
    /// - Parameter keyId: SSH key identifier
    func deleteSSHKey(for keyId: UUID) throws {
        let key = sshKeyKey(for: keyId)
        try delete(for: key, syncToiCloud: true)
        
        // Also delete associated passphrase if exists
        let passphraseKey = sshKeyPassphraseKey(for: keyId)
        try? delete(for: passphraseKey, syncToiCloud: true)
    }
    
    /// Store passphrase for an SSH key
    /// - Parameters:
    ///   - passphrase: The passphrase to store
    ///   - keyId: SSH key identifier
    func storeSSHKeyPassphrase(_ passphrase: String, for keyId: UUID) throws {
        let key = sshKeyPassphraseKey(for: keyId)
        let data = passphrase.data(using: .utf8)!
        try store(data: data, for: key, syncToiCloud: true)
    }
    
    /// Retrieve passphrase for an SSH key
    /// - Parameter keyId: SSH key identifier
    /// - Returns: The stored passphrase, or nil if not stored
    func retrieveSSHKeyPassphrase(for keyId: UUID) -> String? {
        let key = sshKeyPassphraseKey(for: keyId)
        
        do {
            let data = try retrieve(for: key, syncToiCloud: true)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    // MARK: - Cloud Provider Token Methods
    
    /// Store API token for a cloud provider
    /// - Parameters:
    ///   - token: The API token to store
    ///   - provider: The server provider
    func storeProviderToken(_ token: String, for provider: ServerProvider) throws {
        let data = token.data(using: .utf8)!
        try store(data: data, for: provider.apiTokenKey)
    }
    
    /// Retrieve API token for a cloud provider
    /// - Parameter provider: The server provider
    /// - Returns: The stored API token
    func retrieveProviderToken(for provider: ServerProvider) throws -> String {
        let data = try retrieve(for: provider.apiTokenKey)
        
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        
        return token
    }
    
    /// Delete API token for a cloud provider
    /// - Parameter provider: The server provider
    func deleteProviderToken(for provider: ServerProvider) throws {
        try delete(for: provider.apiTokenKey)
    }
    
    // MARK: - Private Methods
    
    private func passwordKey(for serverId: UUID) -> String {
        return "password_\(serverId.uuidString)"
    }

    private func providerAPIKeyKey(for provider: ClaudeModelProvider) -> String {
        switch provider {
        case .anthropic:
            return "anthropic_api_key"
        default:
            return "claude_provider_api_key_\(provider.rawValue)"
        }
    }

    static func openCodeAPIKeyAccount(for providerID: String) -> String {
        let sanitized = providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "_" || character == "-" ? character : "_"
            }
        return "opencode_provider_api_key_\(String(sanitized))"
    }

    static func openCodeAPIKeyAccount(for providerID: String, serverID: UUID) -> String {
        "\(openCodeAPIKeyAccount(for: providerID))_server_\(serverID.uuidString)"
    }

    static func openCodeServerPasswordAccount(for serverId: UUID) -> String {
        "opencode_server_password_\(serverId.uuidString)"
    }

    static func openCodeServerUsernameAccount(for serverId: UUID) -> String {
        "opencode_server_username_\(serverId.uuidString)"
    }

    static func legacyClaudeProvider(forOpenCodeProviderID providerID: String) -> ClaudeModelProvider? {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic":
            return .anthropic
        case "zai", "z.ai", "z-ai":
            return .zAI
        case "minimax", "mini-max":
            return .miniMax
        case "moonshot":
            return .moonshot
        default:
            return nil
        }
    }

    private func sshKeyKey(for keyId: UUID) -> String {
        return "sshkey_\(keyId.uuidString)"
    }

    private func sshKeyPassphraseKey(for keyId: UUID) -> String {
        return "sshkey_passphrase_\(keyId.uuidString)"
    }

    private func pushSecretKey(for serverId: UUID) -> String {
        "push_secret_\(serverId.uuidString)"
    }

    private func storePushInstallationId(_ value: String) throws {
        let data = value.data(using: .utf8)!
        try store(data: data, for: "push_installation_id")
    }

    private func retrievePushInstallationId() throws -> String {
        let data = try retrieve(for: "push_installation_id")
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }
    
    
    /// Store data in keychain
    private func store(data: Data, for key: String, syncToiCloud: Bool = false) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: syncToiCloud ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Enable iCloud sync if requested
        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = true
        }
        
        // Try to delete existing item first
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }
    
    /// Retrieve data from keychain
    private func retrieve(for key: String, syncToiCloud: Bool = false) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        // Enable iCloud sync if requested
        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = true
        }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unknown(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        
        return data
    }
    
    /// Delete item from keychain
    private func delete(for key: String, syncToiCloud: Bool = false) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        // Enable iCloud sync if requested
        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = true
        }
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }
    
}

// MARK: - Convenience Extensions

extension Server {
    /// Retrieve stored password
    func retrieveCredentials() throws -> String {
        // Only password authentication is supported
        return try KeychainManager.shared.retrievePassword(for: id)
    }
}
