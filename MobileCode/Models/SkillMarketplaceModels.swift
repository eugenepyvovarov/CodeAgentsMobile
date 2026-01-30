//
//  SkillMarketplaceModels.swift
//  CodeAgentsMobile
//
//  Purpose: Codable models for skill marketplace manifests
//

import Foundation

struct SkillMarketplaceDocument: Codable, Hashable, Sendable {
    let name: String
    let owner: SkillMarketplaceOwner
    let metadata: SkillMarketplaceMetadata?
    let plugins: [SkillMarketplacePlugin]
}

struct SkillMarketplaceOwner: Codable, Hashable, Sendable {
    let name: String
    let email: String?
}

struct SkillMarketplaceMetadata: Codable, Hashable, Sendable {
    let description: String?
    let version: String?
    let pluginRoot: String?
}

struct SkillMarketplaceAuthor: Codable, Hashable, Sendable {
    let name: String
}

struct SkillMarketplacePlugin: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let source: SkillMarketplacePluginSource
    let description: String?
    let category: String?
    let author: SkillMarketplaceAuthor?
    let keywords: [String]?

    var id: String { name }
}

enum SkillMarketplacePluginSource: Codable, Hashable, Sendable {
    case path(String)
    case github(repo: String, ref: String?, path: String?)
    case url(String)
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case source
        case repo
        case url
        case ref
        case path
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            self = .path(value)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(String.self, forKey: .source)
        switch source {
        case "github":
            let repo = try container.decode(String.self, forKey: .repo)
            let ref = try container.decodeIfPresent(String.self, forKey: .ref)
            let path = try container.decodeIfPresent(String.self, forKey: .path)
            self = .github(repo: repo, ref: ref, path: path)
        case "url":
            let url = try container.decode(String.self, forKey: .url)
            self = .url(url)
        default:
            self = .unknown(source)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .path(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .github(let repo, let ref, let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("github", forKey: .source)
            try container.encode(repo, forKey: .repo)
            try container.encodeIfPresent(ref, forKey: .ref)
            try container.encodeIfPresent(path, forKey: .path)
        case .url(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("url", forKey: .source)
            try container.encode(value, forKey: .url)
        case .unknown(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .source)
        }
    }
}
