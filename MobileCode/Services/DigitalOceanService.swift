//
//  DigitalOceanService.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import Foundation

class DigitalOceanService: CloudProviderProtocol {
    let providerType = "digitalocean"
    var apiToken: String
    private let baseURL = "https://api.digitalocean.com/v2"
    private let session: URLSession
    
    init(apiToken: String, session: URLSession = .shared) {
        self.apiToken = apiToken
        self.session = session
    }
    
    // MARK: - Authentication
    
    func validateToken() async throws -> Bool {
        let url = URL(string: "\(baseURL)/droplets?per_page=1")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (_, response) = try await session.data(for: request)
        
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
        // Default page size is 20; request a full page so larger accounts still list.
        let url = URL(string: "\(baseURL)/droplets?per_page=200")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let dropletsResponse = try decoder.decode(DODropletsResponse.self, from: data)
                
                return dropletsResponse.droplets.map { droplet in
                    CloudServer(
                        id: String(droplet.id),
                        name: droplet.name,
                        status: droplet.status,
                        publicIP: droplet.networks.v4.first { $0.type == "public" }?.ipAddress,
                        privateIP: droplet.networks.v4.first { $0.type == "private" }?.ipAddress,
                        region: droplet.region.name,
                        imageInfo: droplet.image.name ?? droplet.image.slug ?? "Unknown image",
                        sizeInfo: droplet.size.slug,
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
        let url = URL(string: "\(baseURL)/droplets/\(id)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let dropletResponse = try decoder.decode(DODropletResponse.self, from: data)
                let droplet = dropletResponse.droplet
                
                return CloudServer(
                    id: String(droplet.id),
                    name: droplet.name,
                    status: droplet.status,
                    publicIP: droplet.networks.v4.first { $0.type == "public" }?.ipAddress,
                    privateIP: droplet.networks.v4.first { $0.type == "private" }?.ipAddress,
                    region: droplet.region.name,
                    imageInfo: droplet.image.name ?? droplet.image.slug ?? "Unknown image",
                    sizeInfo: droplet.size.slug,
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
        let url = URL(string: "\(baseURL)/account/keys?per_page=200")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let keysResponse = try decoder.decode(DOSSHKeysResponse.self, from: data)
                
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
        let url = URL(string: "\(baseURL)/account/keys")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["name": name, "public_key": publicKey]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 201:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let keyResponse = try decoder.decode(DOSSHKeyResponse.self, from: data)
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
        let url = URL(string: "\(baseURL)/account/keys/\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await session.data(for: request)
        
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

    func deleteServer(id: String) async throws {
        let url = URL(string: "\(baseURL)/droplets/\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 204:
                return
            case 401:
                throw CloudProviderError.invalidToken
            case 403:
                throw CloudProviderError.insufficientPermissions
            case 404:
                throw CloudProviderError.serverNotFound
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = errorData["message"] as? String {
                    throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: message)
                }
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to delete server")
            }
        }

        throw CloudProviderError.unknownError
    }
    
    func createServer(name: String, region: String, size: String, image: String, sshKeyIds: [String], userData: String? = nil) async throws -> CloudServer {
        let url = URL(string: "\(baseURL)/droplets")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Create request body
        var body: [String: Any] = [
            "name": name,
            "region": region,
            "size": size,
            "image": image,
            "backups": false,
            "ipv6": true,
            "monitoring": false
        ]
        
        // Add SSH keys if provided
        if !sshKeyIds.isEmpty {
            // Convert string IDs to integers where possible
            let keys: [Any] = sshKeyIds.map { id in
                if let intId = Int(id) {
                    return intId
                }
                return id // Keep as string (fingerprint)
            }
            body["ssh_keys"] = keys
        }
        
        // Add user data (cloud-init) if provided
        if let userData = userData {
            body["user_data"] = userData
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 202: // Accepted
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let dropletResponse = try decoder.decode(DODropletResponse.self, from: data)
                let droplet = dropletResponse.droplet
                
                return CloudServer(
                    id: String(droplet.id),
                    name: droplet.name,
                    status: droplet.status,
                    publicIP: droplet.networks.v4.first { $0.type == "public" }?.ipAddress,
                    privateIP: droplet.networks.v4.first { $0.type == "private" }?.ipAddress,
                    region: droplet.region.name,
                    imageInfo: droplet.image.name ?? droplet.image.slug ?? "Unknown image",
                    sizeInfo: droplet.size.slug,
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
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = errorData["message"] as? String {
                    throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: message)
                }
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to create server")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    // MARK: - Server Options
    
    func listRegions() async throws -> [(id: String, name: String)] {
        let url = URL(string: "\(baseURL)/regions")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let regionsResponse = try decoder.decode(DORegionsResponse.self, from: data)
                
                return regionsResponse.regions
                    .filter { $0.available ?? true }  // Include regions if available is nil or true
                    .map { (id: $0.slug, name: $0.name) }
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch regions")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    // Method with regions info (for internal use)
    func listSizesWithRegions() async throws -> [(id: String, name: String, description: String, regions: [String])] {
        let url = URL(string: "\(baseURL)/sizes?per_page=200")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let sizesResponse = try decoder.decode(DOSizesResponse.self, from: data)
                
                return sizesResponse.sizes
                    .filter { size in
                        // Only include available sizes
                        return size.available
                    }
                    .sorted { $0.priceMonthly < $1.priceMonthly }  // Sort by price, cheapest first
                    .map { size in
                        let priceMonthly = String(format: "$%.0f/mo", size.priceMonthly)
                        let description = "\(size.vcpus) vCPU\(size.vcpus > 1 ? "s" : "") • \(formatMemory(size.memory)) RAM • \(size.disk)GB SSD • \(priceMonthly)"
                        return (id: size.slug, name: size.slug.uppercased(), description: description, regions: size.regions)
                    }
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch sizes")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    func listSizes() async throws -> [(id: String, name: String, description: String)] {
        // Match listSizesWithRegions: DO defaults to 20 sizes without per_page.
        let url = URL(string: "\(baseURL)/sizes?per_page=200")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let sizesResponse = try decoder.decode(DOSizesResponse.self, from: data)
                
                return sizesResponse.sizes
                    .filter { size in
                        // Only include available sizes
                        return size.available
                    }
                    .sorted { $0.priceMonthly < $1.priceMonthly }  // Sort by price, cheapest first
                    .map { size in
                        let priceMonthly = String(format: "$%.0f/mo", size.priceMonthly)
                        let description = "\(size.vcpus) vCPU\(size.vcpus > 1 ? "s" : "") • \(formatMemory(size.memory)) RAM • \(size.disk)GB SSD • \(priceMonthly)"
                        return (id: size.slug, name: size.slug.uppercased(), description: description)
                    }
            case 401:
                throw CloudProviderError.invalidToken
            case 429:
                throw CloudProviderError.rateLimitExceeded
            default:
                throw CloudProviderError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch sizes")
            }
        }
        
        throw CloudProviderError.unknownError
    }
    
    func listImages() async throws -> [(id: String, name: String)] {
        let url = URL(string: "\(baseURL)/images?type=distribution&per_page=200")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let imagesResponse = try decoder.decode(DOImagesResponse.self, from: data)
                
                let availableImages = imagesResponse.images
                    .filter { $0.status == "available" }
                    .compactMap { image -> (id: String, name: String)? in
                        guard let slug = image.slug, !slug.isEmpty else { return nil }
                        return (id: slug, name: image.name)
                    }
                
                print("🔍 DigitalOcean API returned \(imagesResponse.images.count) images, \(availableImages.count) available")
                
                return availableImages
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
    
    private func formatMemory(_ memory: Int) -> String {
        if memory >= 1024 {
            let gb = Double(memory) / 1024.0
            if gb == floor(gb) {
                return String(format: "%.0fGB", gb)
            } else {
                return String(format: "%.1fGB", gb)
            }
        }
        return "\(memory)MB"
    }
}

// MARK: - DigitalOcean API Response Models

private struct DODropletsResponse: Codable {
    let droplets: [DODroplet]
}

private struct DODropletResponse: Codable {
    let droplet: DODroplet
}

private struct DODroplet: Codable {
    let id: Int
    let name: String
    let status: String
    let networks: DONetworks
    let region: DORegion
    let image: DOImage
    let size: DOSize
}

private struct DONetworks: Codable {
    /// DO may omit `v4` when only IPv6 is present.
    let v4: [DONetwork]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v4 = try container.decodeIfPresent([DONetwork].self, forKey: .v4) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case v4
    }
}

private struct DONetwork: Codable {
    let ipAddress: String
    let type: String
}

private struct DORegion: Codable {
    let name: String
    let slug: String
    let available: Bool?
}

private struct DOImage: Codable {
    let name: String?
    /// Custom / snapshot / retired base images often return `slug: null` from DO.
    let slug: String?
}

private struct DOSize: Codable {
    let slug: String
}

private struct DOSSHKeysResponse: Codable {
    let sshKeys: [DOSSHKey]
}

private struct DOSSHKeyResponse: Codable {
    let sshKey: DOSSHKey
}

private struct DOSSHKey: Codable {
    let id: Int
    let name: String
    let fingerprint: String
    let publicKey: String
}

// MARK: - Additional Response Models for Server Options

private struct DORegionsResponse: Codable {
    let regions: [DORegion]
}

private struct DOSizesResponse: Codable {
    let sizes: [DOSizeDetail]
}

private struct DOSizeDetail: Codable {
    let slug: String
    let memory: Int
    let vcpus: Int
    let disk: Int
    let priceMonthly: Double
    let available: Bool
    let regions: [String]
}

private struct DOImagesResponse: Codable {
    let images: [DOImageDetail]
}

private struct DOImageDetail: Codable {
    /// Some distribution rows can omit or null `slug`; skip those when listing.
    let slug: String?
    let name: String
    let status: String
}
