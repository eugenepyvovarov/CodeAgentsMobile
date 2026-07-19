//
//  AppVersionMetadata.swift
//  CodeAgentsMobile
//
//  Purpose: Read and format the app's bundled marketing version and build number.
//

import Foundation

struct AppVersionMetadata: Equatable {
    let marketingVersion: String
    let buildNumber: String

    init(infoDictionary: [String: Any]) {
        marketingVersion = infoDictionary["CFBundleShortVersionString"] as? String ?? ""
        buildNumber = infoDictionary["CFBundleVersion"] as? String ?? ""
    }

    static var current: AppVersionMetadata {
        AppVersionMetadata(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    var displayString: String {
        switch (marketingVersion.isEmpty, buildNumber.isEmpty) {
        case (false, false):
            return "\(marketingVersion) (\(buildNumber))"
        case (false, true):
            return marketingVersion
        case (true, false):
            return buildNumber
        case (true, true):
            return "—"
        }
    }
}
