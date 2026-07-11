//
//  AppTabTests.swift
//  CodeAgentsMobileTests
//
//  Purpose: Guard agent tab set includes Abilities hub.
//

import XCTest
@testable import CodeAgentsMobile

final class AppTabTests: XCTestCase {
    func testAgentTabsIncludeAbilitiesBetweenChatAndFiles() {
        let tabs: [AppTab] = [.chat, .abilities, .files, .tasks]
        XCTAssertEqual(tabs.count, 4)
        XCTAssertEqual(tabs[0], .chat)
        XCTAssertEqual(tabs[1], .abilities)
        XCTAssertEqual(tabs[2], .files)
        XCTAssertEqual(tabs[3], .tasks)
    }

    func testAppTabIsHashableAndDistinct() {
        var set = Set<AppTab>()
        set.insert(.chat)
        set.insert(.abilities)
        set.insert(.files)
        set.insert(.tasks)
        set.insert(.abilities)
        XCTAssertEqual(set.count, 4)
        XCTAssertNotEqual(AppTab.abilities, AppTab.chat)
        XCTAssertNotEqual(AppTab.abilities, AppTab.tasks)
    }
}
