//
//  SkillMarketplaceSeedService.swift
//  CodeAgentsMobile
//
//  Purpose: Seed built-in skill marketplaces on startup.
//

import Foundation
import SwiftData

struct SkillMarketplaceSeedService {
    static let shared = SkillMarketplaceSeedService()

    private struct BuiltinMarketplace {
        let owner: String
        let repo: String
        let displayName: String

        var normalizedOwner: String { owner.lowercased() }
        var normalizedRepo: String { repo.lowercased() }
    }

    private let builtins: [BuiltinMarketplace] = [
        BuiltinMarketplace(owner: "eugenepyvovarov",
                           repo: "mini-apps-skills-marketplace",
                           displayName: "Mini Apps")
    ]

    private init() {}

    func ensureBuiltinSourcesExist(in modelContext: ModelContext) {
        for builtin in builtins {
            do {
                let descriptor = FetchDescriptor<SkillMarketplaceSource>()
                let existingSources = try modelContext.fetch(descriptor)
                let normalizedBuiltin = "\(builtin.normalizedOwner)/\(builtin.normalizedRepo)"

                let hasExistingSource = existingSources.contains { source in
                    source.normalizedKey == normalizedBuiltin
                }
                if hasExistingSource {
                    continue
                }

                let source = SkillMarketplaceSource(owner: builtin.normalizedOwner,
                                                  repo: builtin.normalizedRepo,
                                                  displayName: builtin.displayName.isEmpty ? normalizedBuiltin : builtin.displayName)
                modelContext.insert(source)
            } catch {
                continue
            }
        }

        do {
            try modelContext.save()
        } catch {
            // Keep startup resilient if persistence fails; callers can try again on next launch.
        }
    }
}
