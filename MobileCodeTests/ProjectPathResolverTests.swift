import XCTest
@testable import CodeAgentsMobile

final class ProjectPathResolverTests: XCTestCase {
    func testRelativePathRemovesProjectRootPrefix() {
        let result = ProjectPathResolver.relativePath(
            absolutePath: "/root/project/README.md",
            projectRoot: "/root/project"
        )
        XCTAssertEqual(result, "README.md")
    }

    func testRelativePathHandlesTrailingSlashInRoot() {
        let result = ProjectPathResolver.relativePath(
            absolutePath: "/root/project/docs/guide.md",
            projectRoot: "/root/project/"
        )
        XCTAssertEqual(result, "docs/guide.md")
    }

    func testRelativePathReturnsNilForNonProjectPath() {
        let result = ProjectPathResolver.relativePath(
            absolutePath: "/other/README.md",
            projectRoot: "/root/project"
        )
        XCTAssertNil(result)
    }

    func testRelativePathReturnsNilForRootItself() {
        let result = ProjectPathResolver.relativePath(
            absolutePath: "/root/project",
            projectRoot: "/root/project"
        )
        XCTAssertNil(result)
    }
}

