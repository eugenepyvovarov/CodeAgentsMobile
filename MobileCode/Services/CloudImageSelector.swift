//
//  CloudImageSelector.swift
//  CodeAgentsMobile
//

import Foundation

enum CloudImageSelector {
    static func preferredUbuntuImage(from images: [(id: String, name: String)]) -> String {
        let ubuntuImages = images
            .filter { image in
                let name = image.name.lowercased()
                let id = image.id.lowercased()
                return name.contains("ubuntu") || id.contains("ubuntu")
            }
            .map { image in
                let nameVersion = ubuntuVersion(from: image.name)
                let idVersion = ubuntuVersion(from: image.id)
                let version = bestVersion(nameVersion, idVersion)
                return Candidate(
                    image: image,
                    version: version,
                    isLTS: isLTSImage(image, version: version),
                    isPreferredLTS: version.major == 24 && version.minor == 4
                )
            }

        if let preferred = ubuntuImages
            .filter(\.isPreferredLTS)
            .sorted(by: sortCandidates)
            .first {
            return preferred.image.id
        }

        if let lts = ubuntuImages
            .filter(\.isLTS)
            .sorted(by: sortCandidates)
            .first {
            return lts.image.id
        }

        if let latest = ubuntuImages
            .sorted(by: sortCandidates)
            .first {
            return latest.image.id
        }

        return images.first?.id ?? ""
    }

    static func ubuntuVersion(from value: String) -> (major: Int, minor: Int) {
        let pattern = #"(\d+)[.-](\d+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let majorRange = Range(match.range(at: 1), in: value),
              let minorRange = Range(match.range(at: 2), in: value),
              let major = Int(value[majorRange]),
              let minor = Int(value[minorRange]) else {
            return (0, 0)
        }

        return (major, minor)
    }

    private struct Candidate {
        let image: (id: String, name: String)
        let version: (major: Int, minor: Int)
        let isLTS: Bool
        let isPreferredLTS: Bool
    }

    private static func bestVersion(
        _ first: (major: Int, minor: Int),
        _ second: (major: Int, minor: Int)
    ) -> (major: Int, minor: Int) {
        if first.major != second.major {
            return first.major > second.major ? first : second
        }

        return first.minor >= second.minor ? first : second
    }

    private static func isLTSImage(
        _ image: (id: String, name: String),
        version: (major: Int, minor: Int)
    ) -> Bool {
        let combined = "\(image.id) \(image.name)".lowercased()
        return combined.contains("lts") || (version.major.isMultiple(of: 2) && version.minor == 4)
    }

    private static func sortCandidates(_ first: Candidate, _ second: Candidate) -> Bool {
        if first.version.major != second.version.major {
            return first.version.major > second.version.major
        }

        if first.version.minor != second.version.minor {
            return first.version.minor > second.version.minor
        }

        return first.image.name < second.image.name
    }
}
