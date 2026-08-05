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
            maxPageHeight: 200,
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
              div.ot {
                border: 1px solid #000;
                padding: 3px 7px;
                margin: 3px auto 3px -7px;
                display: inline-block;
                border-radius: 0px 10px 10px;
                background-color: #FFFF99;
                float: left;
              }
            </style>
          </head>
          <body>
            <p>就在这时，手机跳出了一条通知。</p>
            <div class="tk">
              <p>tls123</p>
              <div class="ot"><p>谢谢你。</p></div>
            </div>
            <p>突如其来的讯息映入眼帘。</p>
          </body>
        </html>
        """, config: config)
        let ns = result.attributedString.string as NSString
        var paraDump: [String] = []
        result.attributedString.enumerateAttribute(
            .paragraphStyle, in: NSRange(location: 0, length: result.attributedString.length), options: []
        ) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            paraDump.append("[\(String(ns.substring(with: range).prefix(10)))] before=\(style.paragraphSpacingBefore) after=\(style.paragraphSpacing)")
        }
        let nameRange = ns.range(of: "tls123")
        #expect(nameRange.location != NSNotFound)
        var attrDump: [String] = []
        for key in [HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
                    HTMLAttributedStringBuilder.containerBlockRenderIDAttribute] {
            if let v = result.attributedString.attribute(
                key, at: nameRange.location, longestEffectiveRange: nil, in: NSRange(location: 0, length: result.attributedString.length)
            ) {
                let brs = v as? HTMLAttributedStringBuilder.BlockRenderStyle
                attrDump.append("\(key.rawValue)=\(brs.map { "padT=\($0.paddingTop) bT=\($0.borderTopWidth) psB=\($0.paragraphSpacingBefore)" } ?? String(describing: v))")
            } else {
                attrDump.append("\(key.rawValue)=nil")
            }
        }
        if let nameStyle = result.attributedString.attribute(
            .paragraphStyle, at: nameRange.location, effectiveRange: nil
        ) as? NSParagraphStyle {
            #expect(nameStyle.paragraphSpacingBefore <= 5,
                    "repro paragraphs: \(paraDump.joined(separator: " | ")) || attrs: \(attrDump.joined(separator: " ; "))")
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
