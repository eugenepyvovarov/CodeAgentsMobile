import Foundation
import SwiftData

@Model
final class SSHKey {
    var id = UUID()
    var name: String
    var keyType: String // e.g., "Ed25519", "P256", "P384", "P521"
    var privateKeyIdentifier: String // Reference to key stored in Keychain
    var publicKey: String = "" // Store public key for upload to providers
    var fingerprint: String? // SSH fingerprint from provider
    var createdAt = Date()
    
    init(name: String, keyType: String, privateKeyIdentifier: String) {
        self.name = name
        self.keyType = keyType
        self.privateKeyIdentifier = privateKeyIdentifier
    }
    
    // Computed property to get usage count (will query servers)
    var usageDescription: String {
        // This will be implemented once we have the query logic
        return "Not used yet"
    }
}