import CoreGraphics
import XCTest
@testable import computer_use_server

final class KeyParsingTests: XCTestCase {
    func testNamedKey() throws {
        let stroke = try Input.parse("Return")
        XCTAssertEqual(stroke.code, 36)
        XCTAssertTrue(stroke.modifiers.isEmpty)
    }

    func testWholeWordTextMatch() {
        XCTAssertTrue(Engine.containsWord("ok", "ok"))
        XCTAssertTrue(Engine.containsWord("click ok to continue", "ok"))
        XCTAssertTrue(Engine.containsWord("save as…", "save"))
        XCTAssertFalse(Engine.containsWord("workbook area, sheet1", "ok"))
        XCTAssertFalse(Engine.containsWord("booking", "ok"))
    }

    func testModifiersAndAliases() throws {
        let stroke = try Input.parse("ctrl+shift+Tab")
        XCTAssertEqual(stroke.code, 48)
        XCTAssertEqual(stroke.modifiers.map(\.flag), [.maskControl, .maskShift])
        XCTAssertEqual(try Input.parse("Page_Down").code, 121)
        XCTAssertEqual(try Input.parse("Next").code, 121)
        XCTAssertEqual(try Input.parse("KP_0").code, 82)
        XCTAssertEqual(try Input.parse("F5").code, 96)
    }

    func testModifierOnly() throws {
        let stroke = try Input.parse("super")
        XCTAssertNil(stroke.code)
        XCTAssertEqual(stroke.modifiers.first?.flag, .maskCommand)
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try Input.parse("NotAKey"))
        XCTAssertThrowsError(try Input.parse("hyper+a"))
    }
}

final class DiffTests: XCTestCase {
    func testUnchanged() {
        let lines = [1: "a", 2: "b"]
        XCTAssertEqual(TreeDiff.compute(baseline: lines, lines: lines, order: [1, 2]), .unchanged)
    }

    func testSmallChange() {
        // 3 changes among 10 elements stays under the 50% threshold.
        var base: [Int: String] = [:]
        for i in 1...10 { base[i] = "line \(i)" }
        var new = base
        new[2] = "B"
        new[11] = "f"
        new[5] = nil
        let order = [1, 2, 3, 4, 6, 7, 8, 9, 10, 11]
        XCTAssertEqual(TreeDiff.compute(baseline: base, lines: new, order: order),
                       .changes(["~ B", "+ f", "- line 5"]))
    }

    func testLargeChangeFallsBackToFull() {
        XCTAssertEqual(TreeDiff.compute(baseline: [1: "a", 2: "b"], lines: [3: "c", 4: "d"], order: [3, 4]), .full)
    }
}

final class RenderingTests: XCTestCase {
    func testRoleNames() {
        XCTAssertEqual(Session.roleName("AXButton", nil), "button")
        XCTAssertEqual(Session.roleName("AXButton", "AXCloseButton"), "button(closeButton)")
        XCTAssertEqual(Session.roleName("AXWindow", "AXStandardWindow"), "window")
    }

    func testQuoteEscapesAndTruncates() {
        XCTAssertEqual(Session.quote("a \"b\"\nc"), "\"a \\\"b\\\"\\nc\"")
        XCTAssertEqual(Session.quote(String(repeating: "x", count: 10), max: 4), "\"xxxx…(+6 chars)\"")
    }

    func testActionNames() {
        XCTAssertEqual(AX.displayAction("AXPress"), "Press")
        XCTAssertEqual(AX.displayAction("Name:Reply\nTarget:0x0\nSelector:(null)"), "Reply")
        XCTAssertEqual(AX.normalizeAction("Show Menu"), AX.normalizeAction("AXShowMenu"))
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let html = Markdown.toHTML("# Title\n**bold** and *it*\n- one\n- two\n\n1. first")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<b>bold</b> and <i>it</i>"))
        XCTAssertTrue(html.contains("<ul>\n<li>one</li>\n<li>two</li>\n</ul>"))
        XCTAssertTrue(html.contains("<ol>\n<li>first</li>"))
    }

    func testEscapesAndLinks() {
        XCTAssertEqual(Markdown.inline("a < b & [x](https://e.com)"), "a &lt; b &amp; <a href=\"https://e.com\">x</a>")
        XCTAssertEqual(Markdown.inline("snake_case_name"), "snake_case_name")
    }
}
