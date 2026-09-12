@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct BrowserLayoutFragmentedDecorationTests {
    @Test("three-page bordered block emits page-bounded slice fragments")
    func threePageBorderedBlockUsesSliceGeometry() {
        var style = ComputedStyle(fontSize: 16, color: .black)
        style.borderTopWidth = 2
        style.borderRightWidth = 2
        style.borderBottomWidth = 2
        style.borderLeftWidth = 2
        style.borderTopStyle = .dashed
        style.borderRightStyle = .dashed
        style.borderBottomStyle = .dashed
        style.borderLeftStyle = .dashed
        style.borderColor = .red
        style.borderRadius = 8
        style.backgroundColor = .yellow

        let lines = (0..<6).map { index in
            let sourceRange = NSRange(location: index * 2, length: 2)
            let run = LineRun(
                sourceRange: sourceRange,
                x: 0,
                width: 40,
                style: style,
                font: InlineLayout.font(for: style),
                nodeID: 42,
                linkTarget: nil,
                atomic: nil
            )
            return LayoutLine(
                runs: [run],
                height: 40,
                ascent: 30,
                descent: 10,
                top: CGFloat(index) * 40,
                baseline: CGFloat(index) * 40 + 30,
                contentX: 0,
                ctLine: nil
            )
        }
        let block = BlockBox(style: style, lines: lines)
        block.debugNodeID = 42
        let root = BlockBox(
            style: ComputedStyle(fontSize: 16, color: .black),
            children: [block]
        )
        root.debugNodeID = 1
        _ = BlockLayout.layOut(root: root, containerWidth: 300)

        let pages = PageFragmentation.fragment(
            box: root,
            pageSize: CGSize(width: 300, height: 100)
        )
        let fillsByPage = pages.map { page in
            page.fragments.compactMap { fragment -> FillFragment? in
                guard case .fill(let fill) = fragment, fill.nodeID == 42 else { return nil }
                return fill
            }
        }

        #expect(pages.count == 3)
        #expect(fillsByPage.map(\.count) == [1, 1, 1])
        for fills in fillsByPage {
            for fill in fills {
                #expect(fill.rect.minY >= 0)
                #expect(fill.rect.maxY <= 100)
            }
        }

        let fills = fillsByPage.compactMap(\.first)
        #expect(fills.allSatisfy { $0.color == .yellow })
        if fills.count == 3 {
            #expect(fills.map(\.fragmentPosition) == [.first, .middle, .last])
            #expect(fills[0].borderTop.isVisible)
            #expect(!fills[0].borderBottom.isVisible)
            #expect(!fills[1].borderTop.isVisible)
            #expect(!fills[1].borderBottom.isVisible)
            #expect(!fills[2].borderTop.isVisible)
            #expect(fills[2].borderBottom.isVisible)
            #expect(fills.allSatisfy { $0.borderLeft.isVisible && $0.borderRight.isVisible })
        }

        let sourceRanges = pages.flatMap { page in
            page.fragments.compactMap { fragment -> NSRange? in
                guard case .text(let text) = fragment else { return nil }
                return text.sourceRange
            }
        }
        #expect(sourceRanges == lines.flatMap(\.runs).map(\.sourceRange))
    }
}
