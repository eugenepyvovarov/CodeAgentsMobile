//
//  HetznerCloudService.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import Foundation

class HetznerCloudService: CloudProviderProtocol {
    let providerType = "hetzner"
    var apiToken: String
    private let baseURL = "https://api.hetzner.cloud/v1"
    
    init(apiToken: String) {
        self.apiToken = apiToken
    }
    
    // MARK: - Authentication
    
    func validateToken() async throws -> Bool {
        let url = URL(string: "\(baseURL)/servers")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                return true
            case 401:
                throw CloudProviderError.invalidToken
            case 403:
                throw CloudProviderError.insufficientPermissions
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to validate token")
            }
        }
        
        return false
    }
    
    // MARK: - Server Management
    
    func listServers() async throws -> [CloudServer] {
        let url = URL(string: "\(baseURL)/servers")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let serversResponse = try decoder.decode(HCServersResponse.self, from: data)
                
                return serversResponse.servers.map { server in
                    CloudServer(
                        id: String(server.id),
                        name: server.name,
                        status: server.status,
                        publicIP: server.publicNet.ipv4?.ip,
                        privateIP: server.privateNet.first?.ip,
                        region: server.datacenter.location.name,
                        imageInfo: server.image.name ?? server.image.description ?? "Image \(server.image.id)",
                        sizeInfo: server.serverType.name,
                        providerType: providerType
                    )
                }
            case 401:
                throw CloudProviderError.invalidToken
            case 403:
                throw CloudProviderError.insufficientPermissions
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch servers")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    func getServer(id: String) async throws -> CloudServer? {
        let url = URL(string: "\(baseURL)/servers/\(id)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let serverResponse = try decoder.decode(HCServerResponse.self, from: data)
                let server = serverResponse.server
                
                return CloudServer(
                    id: String(server.id),
                    name: server.name,
                    status: server.status,
                    publicIP: server.publicNet.ipv4?.ip,
                    privateIP: server.privateNet.first?.ip,
                    region: server.datacenter.location.name,
                    imageInfo: server.image.name ?? server.image.description ?? "Image \(server.image.id)",
                    sizeInfo: server.serverType.name,
                    providerType: providerType
                )
            case 404:
                return nil
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch server")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    // MARK: - SSH Key Management
    
    func listSSHKeys() async throws -> [CloudSSHKey] {
        let url = URL(string: "\(baseURL)/ssh_keys")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let keysResponse = try decoder.decode(HCSSHKeysResponse.self, from: data)
                
                return keysResponse.sshKeys.map { key in
                    CloudSSHKey(
                        id: String(key.id),
                        name: key.name,
                        fingerprint: key.fingerprint,
                        publicKey: key.publicKey
                    )
                }
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch SSH keys")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    func addSSHKey(name: String, publicKey: String) async throws -> CloudSSHKey {
        let url = URL(string: "\(baseURL)/ssh_keys")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["name": name, "public_key": publicKey]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 201:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let keyResponse = try decoder.decode(HCSSHKeyResponse.self, from: data)
                let key = keyResponse.sshKey
                
                return CloudSSHKey(
                    id: String(key.id),
                    name: key.name,
                    fingerprint: key.fingerprint,
                    publicKey: key.publicKey
                )
            case 401:
                throw CloudProviderError.invalidToken
            case 403:
                throw CloudProviderError.insufficientPermissions
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to add SSH key")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    func deleteSSHKey(id: String) async throws {
        let url = URL(string: "\(baseURL)/ssh_keys/\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 204:
                return
            case 401:
                throw CloudProviderError.invalidToken
            case 403:
                throw CloudProviderError.insufficientPermissions
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to delete SSH key")
            }
        }
    }
    
    // MARK: - Server Creation
    
    func createServer(name: String, region: String, size: String, image: String, sshKeyIds: [String], userData: String? = nil) async throws -> CloudServer {
        let url = URL(string: "\(baseURL)/servers")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Create request body for Hetzner
        // Note: Hetzner uses location OR datacenter, and server_type instead of size
        var body: [String: Any] = [
            "name": name,
            "server_type": size, // In Hetzner, this is like "cx11", "cpx11", etc.
            "image": image, // Image name or ID
            "start_after_create": true
        ]
        
        // Hetzner uses location (e.g., "fsn1") or datacenter
        if !region.isEmpty {
            body["location"] = region
        }
        
        // Add SSH keys if provided (Hetzner expects array of integers)
        if !sshKeyIds.isEmpty {
            let keyIds = sshKeyIds.compactMap { Int($0) }
            if !keyIds.isEmpty {
                body["ssh_keys"] = keyIds
            }
        }
        
        // Add user data (cloud-init) if provided
        if let userData = userData {
            body["user_data"] = userData
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 201: // Created
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let serverResponse = try decoder.decode(HCServerResponse.self, from: data)
                let server = serverResponse.server
                
                return CloudServer(
                    id: String(server.id),
                    name: server.name,
                    status: server.status,
                    publicIP: server.publicNet.ipv4?.ip,
                    privateIP: server.privateNet.first?.ip,
                    region: server.datacenter.location.name,
                    imageInfo: server.image.name ?? server.image.description ?? "Image \(server.image.id)",
                    sizeInfo: server.serverType.name,
                    providerType: providerType
                )
            case 401:
                throw CloudProviderError.invalidToken
            case 403:
                throw CloudProviderError.insufficientPermissions
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                // Try to parse error message
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let error = errorData["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: message)
                    }
                }
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to create server")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    // MARK: - Server Options
    
    func listRegions() async throws -> [(id: String, name: String)] {
        let url = URL(string: "\(baseURL)/locations")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let locationsResponse = try decoder.decode(HCLocationsResponse.self, from: data)
                
                return locationsResponse.locations.map { location in
                    let displayName = [location.city, location.country]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                    return (id: location.name, name: displayName.isEmpty ? location.name : displayName)
                }
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch locations")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    func listSizes() async throws -> [(id: String, name: String, description: String)] {
        let url = URL(string: "\(baseURL)/server_types")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let typesResponse = try decoder.decode(HCServerTypesResponse.self, from: data)
                
                return typesResponse.serverTypes
                    .filter { type in
                        // Filter out deprecated server types
                        if type.deprecated == true {
                            return false
                        }
                        // Also check if deprecation is set (even if deprecated flag is not)
                        if type.deprecation != nil {
                            return false
                        }
                        return true
                    }
                    .sorted { ($0.prices.first?.priceMonthly.grossValue ?? 0) < ($1.prices.first?.priceMonthly.grossValue ?? 0) }  // Sort by price
                    .map { type in
                        let priceMonthly = String(format: "€%.2f/mo", type.prices.first?.priceMonthly.grossValue ?? 0)
                        let description = "\(type.cores) vCPU\(type.cores > 1 ? "s" : "") • \(Int(type.memory))GB RAM • \(type.disk)GB SSD • \(priceMonthly)"
                        return (id: type.name, name: type.description, description: description)
                    }
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch server types")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    func listImages() async throws -> [(id: String, name: String)] {
        let url = URL(string: "\(baseURL)/images?type=system")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let imagesResponse = try decoder.decode(HCImagesResponse.self, from: data)
                
                return imagesResponse.images
                    .filter { $0.status == "available" }
                    .map { (id: $0.name ?? String($0.id), name: $0.description ?? $0.name ?? "Image \($0.id)") }
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch images")
            }
        }
        
        throw CloudProviderError.unknownError
    }
}

// MARK: - Hetzner Cloud API Response Models

private struct HCServersResponse: Codable {
    let servers: [HCServer]
}

private struct HCServerResponse: Codable {
    let server: HCServer
}

private struct HCServer: Codable {
    let id: Int
    let name: String
    let status: String
    let publicNet: HCPublicNet
    let privateNet: [HCPrivateNet]
    let datacenter: HCDatacenter
    let image: HCImage
    let serverType: HCServerType
}

private struct HCPublicNet: Codable {
    let ipv4: HCIPv4?
    let ipv6: HCIPv6?
}

private struct HCIPv4: Codable {
    let ip: String
}

private struct HCIPv6: Codable {
    let ip: String
}

private struct HCPrivateNet: Codable {
    let ip: String
}

private struct HCDatacenter: Codable {
    let location: HCLocation
}

private struct HCLocation: Codable {
    let id: Int?
    let name: String
    let city: String?
    let country: String?
}

private struct HCImage: Codable {
    let id: Int
    let name: String?
    let description: String?
}

private struct HCServerType: Codable {
    let name: String
}

private struct HCSSHKeysResponse: Codable {
    let sshKeys: [HCSSHKey]
}

private struct HCSSHKeyResponse: Codable {
    let sshKey: HCSSHKey
}

private struct HCSSHKey: Codable {
    let id: Int
    let name: String
    let fingerprint: String
    let publicKey: String
}

// MARK: - Additional Response Models for Server Options

private struct HCLocationsResponse: Codable {
    let locations: [HCLocation]
}

private struct HCServerTypesResponse: Codable {
    let serverTypes: [HCServerTypeDetail]
}

private struct HCServerTypeDetail: Codable {
    let id: Int
    let name: String
    let description: String
    let cores: Int
    let memory: Double
    let disk: Int
    let prices: [HCPrice]
    let deprecated: Bool?
    let deprecation: HCDeprecation?
}

private struct HCDeprecation: Codable {
    let unavailableAfter: String?
    let announced: String?
}

private struct HCPrice: Codable {
    let priceMonthly: HCPriceValue
}

private struct HCPriceValue: Codable {
    let gross: String
    
    var grossValue: Double {
        return Double(gross) ?? 0.0
    }
}

private struct HCImagesResponse: Codable {
    let images: [HCImageDetail]
}

private struct HCImageDetail: Codable {
    let id: Int
    let name: String?
    let description: String?
    let status: String
}