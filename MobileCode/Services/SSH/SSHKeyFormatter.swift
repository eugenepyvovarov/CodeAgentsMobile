//
//  SSHKeyFormatter.swift
//  CodeAgentsMobile
//
//  Purpose: Utility class for formatting SSH public keys in OpenSSH format
//

import Foundation
import Crypto

/// Utility class for formatting SSH keys in various formats
class SSHKeyFormatter {
    
    /// Format an Ed25519 public key in OpenSSH format
    /// - Parameters:
    ///   - keyData: The raw public key data (32 bytes)
    ///   - name: The key name/comment to append
    /// - Returns: OpenSSH formatted public key string
    static func formatEd25519PublicKey(_ keyData: Data, name: String) -> String {
        // Build SSH format for Ed25519
        var data = Data()
        
        // Add key type
        let keyType = "ssh-ed25519"
        let typeData = keyType.data(using: .utf8)!
        var typeLength = UInt32(typeData.count).bigEndian
        data.append(Data(bytes: &typeLength, count: 4))
        data.append(typeData)
        
        // Add public key
        var keyLength = UInt32(keyData.count).bigEndian
        data.append(Data(bytes: &keyLength, count: 4))
        data.append(keyData)
        
        return "\(keyType) \(data.base64EncodedString()) \(name)"
    }
    
    /// Format an ECDSA public key in OpenSSH format
    /// - Parameters:
    ///   - keyData: The raw public key data
    ///   - curve: The curve identifier (nistp256, nistp384, nistp521)
    ///   - name: The key name/comment to append
    /// - Returns: OpenSSH formatted public key string
    static func formatECDSAPublicKey(_ keyData: Data, curve: String, name: String) -> String {
        // Build SSH format for ECDSA
        var data = Data()
        
        // Add key type
        let keyType = "ecdsa-sha2-\(curve)"
        let typeData = keyType.data(using: .utf8)!
        var typeLength = UInt32(typeData.count).bigEndian
        data.append(Data(bytes: &typeLength, count: 4))
        data.append(typeData)
        
        // Add curve identifier
        let curveData = curve.data(using: .utf8)!
        var curveLength = UInt32(curveData.count).bigEndian
        data.append(Data(bytes: &curveLength, count: 4))
        data.append(curveData)
        
        // Add public key (for ECDSA, it needs to be in uncompressed format: 0x04 || x || y)
        // The rawRepresentation from swift-crypto gives us just x || y (64 bytes for P256)
        // We need to add the 0x04 prefix for SSH format
        var publicKeyWithPrefix = Data([0x04])
        publicKeyWithPrefix.append(keyData)
        
        var keyLength = UInt32(publicKeyWithPrefix.count).bigEndian
        data.append(Data(bytes: &keyLength, count: 4))
        data.append(publicKeyWithPrefix)
        
        return "\(keyType) \(data.base64EncodedString()) \(name)"
    }
    
    /// Extract and format public key from private key data
    /// - Parameters:
    ///   - privateKeyData: The private key data
    ///   - keyType: The key type (Ed25519, P256, P384, P521)
    ///   - passphrase: Optional passphrase for encrypted keys
    ///   - name: The key name/comment to append
    /// - Returns: OpenSSH formatted public key string, or nil if extraction fails
    static func extractPublicKey(from privateKeyData: Data, keyType: String, passphrase: String? = nil, name: String) -> String? {
        do {
            // Parse the private key to get access to the key object and public key data
            let parseResult = try SSHKeyParserV2.parse(keyData: privateKeyData, passphrase: passphrase)
            
            // Use the public key data from the parse result
            guard let publicKeyData = parseResult.publicKeyData else {
                print("No public key data available for key type: \(keyType)")
                return nil
            }
            
            // Format the public key based on type
            switch keyType {
            case "Ed25519":
                return formatEd25519PublicKey(publicKeyData, name: name)
                
            case "P256":
                return formatECDSAPublicKey(publicKeyData, curve: "nistp256", name: name)
                
            case "P384":
                return formatECDSAPublicKey(publicKeyData, curve: "nistp384", name: name)
                
            case "P521":
                return formatECDSAPublicKey(publicKeyData, curve: "nistp521", name: name)
                
            default:
                print("Unsupported key type for public key extraction: \(keyType)")
                return nil
            }
        } catch {
            print("Failed to extract public key: \(error)")
            return nil
        }
    }
}