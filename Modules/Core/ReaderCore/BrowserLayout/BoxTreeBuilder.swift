import Foundation
import UIKit

/// ComputedStyleNode tree → block box tree. Text under a block becomes inline
/// runs laid out by InlineLayout; block children become child BlockBoxes.
/// Phase 1 synthesizes ONE anonymous block when a block mixes inline content
/// and block children (interleaving order is not preserved — accepted Phase 1).
enum BoxTreeBuilder {

    static func buildBlock(for node: ComputedStyleNode, config: BrowserLayoutConfig) -> BlockBox {
        var kids: [BlockBox] = []
        var pendingInline: [InlineRun] = []

        for child in node.children {
            switch child {
            case .text(let text):
                let collapsed = collapseWhitespace(text)
                if !collapsed.isEmpty {
                    pendingInline.append(InlineRun(text: collapsed, style: node.style))
                }
            case .element(let elementNode):
                if elementNode.style.display == .block {
                    if !pendingInline.isEmpty {
                        kids.append(makeAnonymousBlock(runs: pendingInline, style: node.style, config: config))
                        pendingInline = []
                    }
                    kids.append(buildBlock(for: elementNode, config: config))
                } else if elementNode.style.display == .none {
                    continue
                } else {
                    collectInline(elementNode, into: &pendingInline, config: config)
                }
            }
        }

        let box = BlockBox(style: node.style, boxType: .block, children: kids)
        if !pendingInline.isEmpty {
            box.lines = InlineLayout.layoutLines(
                runs: pendingInline,
                maxWidth: config.renderWidth,
                rootFontSize: config.rootFontSize,
                lineHeight: node.style.lineHeight
            )
        }
        return box
    }

    private static func makeAnonymousBlock(runs: [InlineRun], style: ComputedStyle, config: BrowserLayoutConfig) -> BlockBox {
        let box = BlockBox(style: style, boxType: .anonymous)
        box.lines = InlineLayout.layoutLines(
            runs: runs,
            maxWidth: config.renderWidth,
            rootFontSize: config.rootFontSize,
            lineHeight: style.lineHeight
        )
        return box
    }

    private static func collectInline(_ node: ComputedStyleNode, into runs: inout [InlineRun], config: BrowserLayoutConfig) {
        for child in node.children {
            switch child {
            case .text(let text):
                let collapsed = collapseWhitespace(text)
                if !collapsed.isEmpty {
                    runs.append(InlineRun(text: collapsed, style: node.style))
                }
            case .element(let elementNode):
                collectInline(elementNode, into: &runs, config: config)
            }
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
