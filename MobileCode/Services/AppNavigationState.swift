//
//  AppNavigationState.swift
//  CodeAgentsMobile
//
//  Purpose: Centralized navigation state for deep links / push routing.
//

import Foundation

enum AppTab: Hashable {
    case chat
    case files
    case tasks
}

@MainActor
final class AppNavigationState: ObservableObject {
    static let shared = AppNavigationState()

    @Published var selectedTab: AppTab = .chat

    private init() {}
}

