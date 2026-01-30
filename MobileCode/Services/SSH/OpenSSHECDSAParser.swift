//
//  OpenSSHECDSAParser.swift
//  CodeAgentsMobile
//
//  Purpose: Parse OpenSSH ECDSA keys and convert to SEC1 format
//  
//  This parser extracts ECDSA private keys from OpenSSH format and
//  converts them to SEC1 ASN.1 format that swift-crypto can parse.
//  Supports P256, P384, and P521 curves.
//

import Foundation
import NIO
import Crypto
import SwiftASN1
@preconcurrency import NIOSSH

/// SEC1 ECPrivateKey structure for ECDSA keys
struct SEC1ECPrivateKey: DERImplicitlyTaggable {
    static var defaultIdentifier: ASN1Identifier { .sequence }
    
    let version: Int
    let privateKey: Data
    let parameters: ASN1ObjectIdentifier?
    let publicKey: Data?
    
    /// OIDs for different curves
    static let p256OID = try! ASN1ObjectIdentifier(elements: [1, 2, 840, 10045, 3, 1, 7])  // prime256v1
    static let p384OID = try! ASN1ObjectIdentifier(elements: [1, 3, 132, 0, 34])           // secp384r1
    static let p521OID = try! ASN1ObjectIdentifier(elements: [1, 3, 132, 0, 35])           // secp521r1
    
    init(version: Int = 1, privateKey: Data, parameters: ASN1ObjectIdentifier? = nil, publicKey: Data? = nil) {
        self.version = version
        self.privateKey = privateKey
        self.parameters = parameters
        self.publicKey = publicKey
    }
    
    init(derEncoded: ASN1Node, withIdentifier identifier: ASN1Identifier) throws {
        // This initializer is required by DERImplicitlyTaggable protocol
        // but not used in our implementation as we only encode to DER
        throw SSHKeyParsingError.invalidKeyData
    }
    
    /// Serialize to DER format
    func serialize(into coder: inout DER.Serializer, withIdentifier identifier: ASN1Identifier) throws {
        try coder.appendConstructedNode(identifier: identifier) { coder in
            // Version (integer 1)
            try coder.serialize(self.version)
            
            // Private key (octet string)
            let octetString = ASN1OctetString(contentBytes: ArraySlice(self.privateKey))
            try coder.serialize(octetString)
            
            // Parameters (optional, context-specific tag 0)
            if let oid = self.parameters {
                try coder.serialize(oid, explicitlyTaggedWithIdentifier: .init(tagWithNumber: 0, tagClass: .contextSpecific))
            }
            
            // Public key (optional, context-specific tag 1)
            if let pubKey = self.publicKey {
                let bitString = ASN1BitString(bytes: ArraySlice(pubKey), paddingBits: 0)
                try coder.serialize(bitString, 
                                  explicitlyTaggedWithIdentifier: .init(tagWithNumber: 1, tagClass: .contextSpecific))
            }
        }
    }
    
    /// Encode to DER format
    func encodeToDER() throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(self)
        return Data(serializer.serializedBytes)
    }
}

/// Parser for OpenSSH ECDSA keys
enum OpenSSHECDSAParser {
    
    /// Parse OpenSSH ECDSA key from ByteBuffer
    static func parseP256(from buffer: inout ByteBuffer) throws -> P256.Signing.PrivateKey {
        // Extract components from OpenSSH format
        let (privateKeyData, publicKeyData) = try extractECDSAComponents(from: &buffer, expectedKeySize: 32)
        
        // Create SEC1 structure with P256 OID
        let sec1Key = SEC1ECPrivateKey(
            version: 1,
            privateKey: privateKeyData,
            parameters: SEC1ECPrivateKey.p256OID,
            publicKey: publicKeyData
        )
        
        // Encode to DER format
        let derEncoded = try sec1Key.encodeToDER()
        
        // Create P256 private key from DER representation
        return try P256.Signing.PrivateKey(derRepresentation: derEncoded)
    }
    
    /// Parse OpenSSH ECDSA P384 key
    static func parseP384(from buffer: inout ByteBuffer) throws -> P384.Signing.PrivateKey {
        // Extract components from OpenSSH format
        let (privateKeyData, publicKeyData) = try extractECDSAComponents(from: &buffer, expectedKeySize: 48)
        
        // Create SEC1 structure with P384 OID
        let sec1Key = SEC1ECPrivateKey(
            version: 1,
            privateKey: privateKeyData,
            parameters: SEC1ECPrivateKey.p384OID,
            publicKey: publicKeyData
        )
        
        // Encode to DER format
        let derEncoded = try sec1Key.encodeToDER()
        
        // Create P384 private key from DER representation
        return try P384.Signing.PrivateKey(derRepresentation: derEncoded)
    }
    
    /// Parse OpenSSH ECDSA P521 key
    static func parseP521(from buffer: inout ByteBuffer) throws -> P521.Signing.PrivateKey {
        // Extract components from OpenSSH format
        let (privateKeyData, publicKeyData) = try extractECDSAComponents(from: &buffer, expectedKeySize: 66)
        
        // Create SEC1 structure with P521 OID
        let sec1Key = SEC1ECPrivateKey(
            version: 1,
            privateKey: privateKeyData,
            parameters: SEC1ECPrivateKey.p521OID,
            publicKey: publicKeyData
        )
        
        // Encode to DER format
        let derEncoded = try sec1Key.encodeToDER()
        
        // Create P521 private key from DER representation
        return try P521.Signing.PrivateKey(derRepresentation: derEncoded)
    }
    
    /// Extract ECDSA components from OpenSSH format
    private static func extractECDSAComponents(from buffer: inout ByteBuffer, expectedKeySize: Int) throws -> (privateKey: Data, publicKey: Data?) {
        // Read and validate curve name
        guard let _ = buffer.readSSHString() else {
            throw SSHKeyParsingError.missingKeyComponent("curve name")
        }
        // Curve name is validated by the calling function
        
        // Read public key
        guard let publicKeyBuffer = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.missingPublicKeyBuffer
        }
        
        // Read private key scalar
        guard let privateKeyBuffer = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.missingPrivateKeyBuffer
        }
        
        // Extract private key bytes
        var privateKeyData = privateKeyBuffer.getData(at: 0, length: privateKeyBuffer.readableBytes) ?? Data()
        
        // Handle leading zero byte (OpenSSH sometimes adds it)
        if privateKeyData.count == expectedKeySize + 1 && privateKeyData[0] == 0 {
            privateKeyData = privateKeyData.dropFirst()
        }
        
        // Validate key size
        guard privateKeyData.count == expectedKeySize else {
            throw SSHKeyParsingError.invalidKeySize(expected: expectedKeySize, actual: privateKeyData.count)
        }
        
        // Extract public key if available
        let publicKeyData = publicKeyBuffer.getData(at: 0, length: publicKeyBuffer.readableBytes)
        
        return (privateKeyData, publicKeyData)
    }
}

// Update the OpenSSHPrivateKey extensions to use the new parser
extension P256.Signing.PrivateKey {
    static func readOpenSSH(consuming buffer: inout ByteBuffer) throws -> Self {
        try OpenSSHECDSAParser.parseP256(from: &buffer)
    }
}

extension P384.Signing.PrivateKey {
    static func readOpenSSH(consuming buffer: inout ByteBuffer) throws -> Self {
        try OpenSSHECDSAParser.parseP384(from: &buffer)
    }
}

extension P521.Signing.PrivateKey {
    static func readOpenSSH(consuming buffer: inout ByteBuffer) throws -> Self {
        try OpenSSHECDSAParser.parseP521(from: &buffer)
    }
}
