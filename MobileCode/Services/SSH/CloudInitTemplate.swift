//
//  CloudInitTemplate.swift
//  CodeAgentsMobile
//
//  Purpose: Manages cloud-init template loading and SSH key replacement
//

import Foundation

struct CloudInitTemplate {
    /// Load the cloud-init template and replace SSH keys placeholder
    /// - Parameter sshKeys: Array of SSH public keys to insert
    /// - Returns: The cloud-init configuration with SSH keys inserted
    static func generate(with sshKeys: [String]) -> String? {
        // Load template from bundle
        guard let templateURL = Bundle.main.url(forResource: "cloud_init_codeagent", withExtension: "yaml"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            print("Warning: Could not load cloud-init template from bundle, using fallback")
            return generateFallback(with: sshKeys)
        }
        
        // Generate SSH keys list in YAML format
        let sshKeysList: String
        if sshKeys.isEmpty {
            // If no keys, provide an empty list
            sshKeysList = "      []"
        } else {
            // Format each key with proper indentation
            let formattedKeys = sshKeys.map { key in
                "      - \(key.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n")
            sshKeysList = formattedKeys
        }
        
        // Replace placeholder with actual SSH keys
        let cloudInit = template.replacingOccurrences(of: "{{SSH_KEYS_PLACEHOLDER}}", with: sshKeysList)
        
        return cloudInit
    }
    
    /// Fallback cloud-init generation if template file is not available
    /// - Parameter sshKeys: Array of SSH public keys to insert
    /// - Returns: The cloud-init configuration
    private static func generateFallback(with sshKeys: [String]) -> String {
        var script = """
#cloud-config
users:
  - name: codeagent
    groups: users, admin, sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
"""
        
        // Add SSH keys if any are provided
        if !sshKeys.isEmpty {
            let sshKeysList = sshKeys.map { key in
                "      - \(key.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n")
            script += "\n    ssh_authorized_keys:\n\(sshKeysList)"
        } else {
            script += "\n    ssh_authorized_keys: []"
        }
        
        // Add the rest of the configuration
        script += """

package_update: true
package_upgrade: true

packages:
  - nodejs
  - npm
  - curl
  - build-essential
  - git

runcmd:
  - npm install -g @anthropic-ai/claude-code
"""
        
        return script
    }
}