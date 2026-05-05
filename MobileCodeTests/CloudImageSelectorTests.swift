//
//  CloudImageSelectorTests.swift
//  CodeAgentsMobileTests
//

import XCTest
@testable import CodeAgentsMobile

final class CloudImageSelectorTests: XCTestCase {
    func testPrefersUbuntu2404LTSOverNewerNonLTS() {
        let images = [
            (id: "ubuntu-25-10-x64", name: "Ubuntu 25.10 x64"),
            (id: "ubuntu-24-10-x64", name: "Ubuntu 24.10 x64"),
            (id: "ubuntu-24-04-x64", name: "Ubuntu 24.04 (LTS) x64"),
            (id: "ubuntu-22-04-x64", name: "Ubuntu 22.04 (LTS) x64")
        ]

        XCTAssertEqual(
            CloudImageSelector.preferredUbuntuImage(from: images),
            "ubuntu-24-04-x64"
        )
    }

    func testFallsBackToLatestLTSWhenUbuntu2404IsUnavailable() {
        let images = [
            (id: "ubuntu-25-10-x64", name: "Ubuntu 25.10 x64"),
            (id: "ubuntu-26-04-x64", name: "Ubuntu 26.04 LTS x64"),
            (id: "ubuntu-22-04-x64", name: "Ubuntu 22.04 LTS x64")
        ]

        XCTAssertEqual(
            CloudImageSelector.preferredUbuntuImage(from: images),
            "ubuntu-26-04-x64"
        )
    }

    func testFallsBackToLatestUbuntuWhenNoLTSExists() {
        let images = [
            (id: "debian-12-x64", name: "Debian 12 x64"),
            (id: "ubuntu-23-10-x64", name: "Ubuntu 23.10 x64"),
            (id: "ubuntu-22-10-x64", name: "Ubuntu 22.10 x64")
        ]

        XCTAssertEqual(
            CloudImageSelector.preferredUbuntuImage(from: images),
            "ubuntu-23-10-x64"
        )
    }
}
