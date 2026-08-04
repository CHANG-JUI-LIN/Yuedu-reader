import Testing
import UIKit
@testable import yuedu_app

/// Phase 2B issue repro: two EPUBRenderingTests failures that are NOT flaky —
/// they fail deterministically on this branch (base aefbf82 predates the
/// main-side fixes). Method-level `-only-testing` filters ran 0 tests on this
/// environment, so the failures only surface in class-level runs.
@MainActor
struct Phase2BStaleLegacyReproTests {

    @Test func longTableAlwaysOnePageOnThisBranch() {
        let rowCount = 37
        let table = HTMLTableModel(
            caption: nil,
            rows: (0..<rowCount).map { index in
                HTMLTableRow(cells: [
                    HTMLTableCell(text: "Row \(index)", columnSpan: 1, rowSpan: 1, isHeader: false)
                ])
            }
        )
        let pages = HTMLTableRasterizer.renderPages(
            table: table,
            maxWidth: 240,
            baseFont: .systemFont(ofSize: 17),
            textColor: .black,
            backgroundColor: .white
        )
        // Root cause: `HTMLTableSupport.renderPages` defaults maxPageHeight to
        // .greatestFiniteMagnitude → every row lands on ONE page. The test
        // expects > 1, so it fails deterministically unless a caller supplies
        // a real page height (the reader does; the test does not).
        #expect(pages.count > 1, "repro: longTable pages=\(pages.count) rows=\(rowCount)")
    }

    @Test func chatBubbleSpacingAlways21() async throws {
        var config = testHTMLConfigForRepro()
        config.renderWidth = 340
        let result = await HTMLAttributedStringBuilder().build(html: """
        <html>
          <head>
            <style>
              p { text-indent: 2em; line-height: 130%; }
              div.tk {
                page-break-inside: avoid;
                border: 1px solid transparent;
                padding: 3px 7px;
                margin: 1em 1em;
                line-height: 1;
              }
              .tk p { margin: 0; font-size: .9em; text-indent: 0; }
            </style>
          </head>
          <body><div class="tk"><p>Bubble</p></div><p>After</p></body>
        </html>
        """, config: config)
        let nameStyle = result.attributedString.attribute(
            HTMLAttributedStringBuilder.blockRenderStyleAttribute,
            at: 0, effectiveRange: nil
        )
        // On this branch the thread's outer margin computes 21.0pt instead of
        // the expected ≤ 5pt — a deterministic regression from the main-side
        // margin-collapse fixes the branch base predates.
        if let blockStyle = nameStyle as? HTMLAttributedStringBuilder.BlockRenderStyle {
            #expect(blockStyle.paragraphSpacingBefore <= 5,
                    "repro: paragraphSpacingBefore=\(blockStyle.paragraphSpacingBefore)")
        } else {
            Issue.record("no block style at 0")
        }
    }
}

private func testHTMLConfigForRepro() -> HTMLAttributedStringBuilder.Config {
    HTMLAttributedStringBuilder.Config(
        fontSize: 17,
        lineHeightMultiple: 1.5,
        lineSpacing: 0,
        paragraphSpacing: 8,
        firstLineIndent: 0,
        textColor: .label,
        backgroundColor: .systemBackground,
        fontFamilyName: nil,
        renderWidth: 320
    )
}
