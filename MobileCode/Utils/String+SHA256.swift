//
//  String+SHA256.swift
//  CodeAgentsMobile
//
//  Purpose: Small helpers for stable push identifiers.
//

import Foundation
import Crypto

extension String {
    func sha256Hex() -> String {
        let digest = SHA256.hash(data: Data(utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

