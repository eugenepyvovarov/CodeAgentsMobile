import XCTest
@testable import CodeAgentsMobile

final class CodeAgentsUIValidationTests: XCTestCase {
    func testProjectRelativePathSanitizerRejectsInvalidPaths() {
        XCTAssertNil(ProjectRelativePathSanitizer.sanitize("/absolute/path.png"))
        XCTAssertNil(ProjectRelativePathSanitizer.sanitize("~/image.png"))
        XCTAssertNil(ProjectRelativePathSanitizer.sanitize("../image.png"))
        XCTAssertNil(ProjectRelativePathSanitizer.sanitize("images/../secret.png"))
        XCTAssertNil(ProjectRelativePathSanitizer.sanitize("images//photo.png"))
    }

    func testProjectRelativePathSanitizerNormalizesPaths() {
        XCTAssertEqual(ProjectRelativePathSanitizer.sanitize("./images/photo.png"), "images/photo.png")
        XCTAssertEqual(ProjectRelativePathSanitizer.sanitize("images\\photo.png"), "images/photo.png")
    }

    func testParseBlockRejectsWrongTypeOrVersion() {
        let wrongType = """
        { "type": "codeagents", "version": 1, "elements": [] }
        """
        XCTAssertNil(CodeAgentsUIParser.parseBlock(from: wrongType))

        let wrongVersion = """
        { "type": "codeagents_ui", "version": 2, "elements": [] }
        """
        XCTAssertNil(CodeAgentsUIParser.parseBlock(from: wrongVersion))
    }

    func testParseBlockPadsTableRows() {
        let json = """
        {
          "type": "codeagents_ui",
          "version": 1,
          "elements": [
            {
              "type": "table",
              "id": "t1",
              "columns": ["A", "B"],
              "rows": [["1"]]
            }
          ]
        }
        """

        guard let block = CodeAgentsUIParser.parseBlock(from: json) else {
            XCTFail("Expected block")
            return
        }

        guard case .table(let table) = block.elements.first else {
            XCTFail("Expected table element")
            return
        }

        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].count, 2)
        XCTAssertEqual(table.rows[0][1], "")
    }

    func testParseBlockRejectsInvalidProjectFilePath() {
        let json = """
        {
          "type": "codeagents_ui",
          "version": 1,
          "elements": [
            {
              "type": "image",
              "id": "img1",
              "source": { "kind": "project_file", "path": "../secret.png" }
            }
          ]
        }
        """

        XCTAssertNil(CodeAgentsUIParser.parseBlock(from: json))
    }

    func testParseGalleryAcceptsMediaSourceEntries() {
        let json = """
        {
          "type": "codeagents_ui",
          "version": 1,
          "elements": [
            {
              "type": "gallery",
              "id": "g1",
              "images": [
                { "kind": "project_file", "path": "images/a.png" },
                { "kind": "project_file", "path": "images/b.png" }
              ]
            }
          ]
        }
        """

        guard let block = CodeAgentsUIParser.parseBlock(from: json) else {
            XCTFail("Expected block")
            return
        }

        guard case .gallery(let gallery) = block.elements.first else {
            XCTFail("Expected gallery element")
            return
        }

        XCTAssertEqual(gallery.images.count, 2)
    }

    func testParseImageAcceptsImagesArray() {
        let json = """
        {
          "type": "codeagents_ui",
          "version": 1,
          "elements": [
            {
              "type": "image",
              "id": "img1",
              "images": [
                { "kind": "project_file", "path": "images/a.png" }
              ]
            }
          ]
        }
        """

        guard let block = CodeAgentsUIParser.parseBlock(from: json) else {
            XCTFail("Expected block")
            return
        }

        guard case .image(let image) = block.elements.first else {
            XCTFail("Expected image element")
            return
        }

        switch image.source {
        case .projectFile(let path):
            XCTAssertEqual(path, "images/a.png")
        default:
            XCTFail("Expected project file source")
        }
    }

    func testParseHeatmapChart() {
        let json = """
        {
          "type": "codeagents_ui",
          "version": 1,
          "elements": [
            {
              "type": "chart",
              "id": "h1",
              "chartType": "heatmap",
              "levels": 4,
              "weekStart": "sun",
              "days": [
                { "date": "2026-02-01", "value": 2 },
                { "date": "2026-02-02", "level": 3 }
              ]
            }
          ]
        }
        """

        guard let block = CodeAgentsUIParser.parseBlock(from: json) else {
            XCTFail("Expected block")
            return
        }

        guard case .chart(let chart) = block.elements.first else {
            XCTFail("Expected chart element")
            return
        }

        guard case .heatmap(let heatmap) = chart.kind else {
            XCTFail("Expected heatmap chart")
            return
        }

        XCTAssertEqual(heatmap.levels, 4)
        XCTAssertEqual(heatmap.weekStart, .sun)
        XCTAssertEqual(heatmap.days.count, 2)
    }
}
