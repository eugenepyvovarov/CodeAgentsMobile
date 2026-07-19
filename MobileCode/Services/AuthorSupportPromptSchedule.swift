//
//  AuthorSupportPromptSchedule.swift
//  CodeAgentsMobile
//
//  Purpose: Persist the recurring author-support prompt schedule and opt-out.
//

import Foundation

struct AuthorSupportPromptSchedule {
    static let recurrenceInterval: TimeInterval = 14 * 24 * 60 * 60

    enum StorageKey {
        static let lastPresentedAt = "authorSupportPrompt.lastPresentedAt.v1"
        static let neverShowAgain = "authorSupportPrompt.neverShowAgain.v1"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func shouldPresent(at date: Date = Date()) -> Bool {
        guard !userDefaults.bool(forKey: StorageKey.neverShowAgain) else {
            return false
        }

        guard let storedValue = userDefaults.object(forKey: StorageKey.lastPresentedAt) else {
            return true
        }
        guard let lastPresentedAt = storedValue as? Date else {
            return true
        }

        return date.timeIntervalSince(lastPresentedAt) >= Self.recurrenceInterval
    }

    func recordPresentation(at date: Date = Date()) {
        userDefaults.set(date, forKey: StorageKey.lastPresentedAt)
    }

    func optOutPermanently() {
        userDefaults.set(true, forKey: StorageKey.neverShowAgain)
    }
}
