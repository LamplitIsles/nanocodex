import XCTest
@testable import NanocodexUI

final class ChatMarkdownTests: XCTestCase {
    func testCodePreservesIndentationAndLiteralMarkdown() {
        let blocks = ChatMarkdownBlock.parse("Before\n\n```swift\n    let marker = \"**literal**\"\n```\n\nAfter")
        XCTAssertEqual(blocks.count, 3)
        guard case .code("swift") = blocks[1].kind else { return XCTFail("Expected a code block") }
        XCTAssertEqual(String(blocks[1].text.characters), "    let marker = \"**literal**\"\n")
        XCTAssertEqual(String(blocks[2].text.characters), "After")
    }

    func testInlineRunsStayTogetherAndKeepLinks() {
        let blocks = ChatMarkdownBlock.parse("# A **heading**\n\nRead [the docs](https://example.com/docs).")
        XCTAssertEqual(blocks.count, 2)
        guard case .text(heading: 1, marker: nil, quote: false) = blocks[0].kind else { return XCTFail("Expected a heading") }
        XCTAssertEqual(String(blocks[0].text.characters), "A heading")
        XCTAssertEqual(String(blocks[1].text.characters), "Read the docs.")
        XCTAssertEqual(blocks[1].text.runs.compactMap(\.link).first?.absoluteString, "https://example.com/docs")
    }

    func testListsQuotesAndTablesRetainTheirStructure() {
        let blocks = ChatMarkdownBlock.parse("- First\n- Second\n\n> A quote\n\n| Name | Value |\n| --- | --- |\n| **A** | `1` |")
        XCTAssertEqual(blocks.count, 4)
        guard case .text(heading: 0, marker: "•", quote: false) = blocks[0].kind,
              case .text(heading: 0, marker: nil, quote: true) = blocks[2].kind,
              case .table(let rows) = blocks[3].kind else { return XCTFail("Expected structured blocks") }
        XCTAssertEqual(rows.map { $0.map { String($0.characters) } }, [["Name", "Value"], ["A", "1"]])
    }

    func testUnclosedStreamingFenceRemainsCode() {
        let blocks = ChatMarkdownBlock.parse("Working\n\n```js\nconst value =")
        XCTAssertEqual(blocks.count, 2)
        guard case .code("js") = blocks[1].kind else { return XCTFail("Expected streamed code") }
        XCTAssertTrue(String(blocks[1].text.characters).contains("const value ="))
    }

    func testSyntaxHighlightingPreservesCodeAndAdaptsToAppearance() async {
        let source = "\n    let greeting = \"Hello 👋 <world> **literal**\"\n\n"
        let light = await ChatCodeHighlighter.highlight(source, language: "swift", dark: false)
        let dark = await ChatCodeHighlighter.highlight(source, language: "swift", dark: true)
        XCTAssertEqual(String(light.characters), source)
        XCTAssertEqual(String(dark.characters), source)
        XCTAssertGreaterThan(light.runs.count, 2)
        XCTAssertNotEqual(light, dark)
    }

    func testStreamingCodeAndUnsupportedLanguagesKeepLiteralContent() async {
        let partial = "\tconst value = \"unfinished"
        let highlighted = await ChatCodeHighlighter.highlight(partial, language: "js", dark: false)
        XCTAssertEqual(String(highlighted.characters), partial)
        XCTAssertGreaterThan(highlighted.runs.count, 1)
        let unknown = await ChatCodeHighlighter.highlight(partial, language: "not-a-code-language", dark: false)
        XCTAssertEqual(String(unknown.characters), partial)
        let empty = await ChatCodeHighlighter.highlight("\n\t ", language: "swift", dark: false)
        XCTAssertEqual(String(empty.characters), "\n\t ")
    }
}
