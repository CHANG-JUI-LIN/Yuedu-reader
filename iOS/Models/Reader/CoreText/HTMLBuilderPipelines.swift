import Foundation
import SwiftSoup
import UIKit

final class HTMLBuilderDOMParser {
    func parse(
        html: String,
        collectStyles: @escaping (Document) async -> [String]
    ) async -> HTMLAttributedStringBuilder.ParsedHTML? {
        guard let document = try? SwiftSoup.parse(html),
              let body = document.body() else {
            return nil
        }

        let stylesheetTexts = await collectStyles(document)
        var regularRules: [CSSRule] = []
        var firstLetterRules: [CSSRule] = []
        for (index, css) in stylesheetTexts.enumerated() {
            let (reg, fl) = CSSParser.parseWithFirstLetter(css: css, orderOffset: index * 10_000)
            regularRules.append(contentsOf: reg)
            firstLetterRules.append(contentsOf: fl)
        }
        return HTMLAttributedStringBuilder.ParsedHTML(body: body, rules: regularRules, firstLetterRules: firstLetterRules)
    }
}

final class HTMLBuilderStyleResolver {
    func buildAST(
        from parsed: HTMLAttributedStringBuilder.ParsedHTML,
        config: HTMLAttributedStringBuilder.Config,
        makeRootStyle: (HTMLAttributedStringBuilder.Config) -> HTMLAttributedStringBuilder.ResolvedStyle,
        resolveStyle: (Element, HTMLAttributedStringBuilder.ResolvedStyle, [CSSRule], CGFloat, Element?, HTMLAttributedStringBuilder.Config) -> HTMLAttributedStringBuilder.ResolvedStyle,
        buildChildren: ([Node], HTMLAttributedStringBuilder.ResolvedStyle, [CSSRule], CGFloat, Element?, HTMLAttributedStringBuilder.Config) async -> [HTMLAttributedStringBuilder.ASTNode],
        makeAttributeMap: (Element) -> [String: String]
    ) async -> HTMLAttributedStringBuilder.ElementNode {
        let bodyStyle = resolveStyle(
            parsed.body,
            makeRootStyle(config),
            parsed.rules,
            config.fontSize,
            nil,
            config
        )
        let astChildren = await buildChildren(
            parsed.body.getChildNodes(),
            bodyStyle,
            parsed.rules,
            config.fontSize,
            parsed.body,
            config
        )
        return HTMLAttributedStringBuilder.ElementNode(
            tag: "body",
            id: parsed.body.id(),
            classes: Array((try? parsed.body.classNames()) ?? []),
            attributes: makeAttributeMap(parsed.body),
            resolvedStyle: bodyStyle,
            children: astChildren
        )
    }
}

final class HTMLBuilderCoreTextRenderer {
    func render(
        ast: HTMLAttributedStringBuilder.ElementNode,
        config: HTMLAttributedStringBuilder.Config,
        renderBlockChildren: ([HTMLAttributedStringBuilder.ASTNode], HTMLAttributedStringBuilder.ResolvedStyle, HTMLAttributedStringBuilder.Config) async -> NSAttributedString,
        collectAnchorOffsets: (NSAttributedString) -> [String: Int],
        backgroundImageSource: (HTMLAttributedStringBuilder.ElementNode) -> String?,
        loadBackgroundImage: (HTMLAttributedStringBuilder.ElementNode) async -> UIImage?,
        debugLog: (NSAttributedString) -> Void
    ) async -> HTMLAttributedStringBuilder.RenderedContent {
        let rendered = await renderBlockChildren(ast.children, ast.resolvedStyle, config)
        let mutable = NSMutableAttributedString(attributedString: rendered)
        if mutable.length > 0 {
            mutable.addAttribute(
                .backgroundColor,
                value: config.backgroundColor,
                range: NSRange(location: 0, length: mutable.length)
            )
            mutable.enumerateAttribute(
                HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                in: NSRange(location: 0, length: mutable.length),
                options: []
            ) { value, range, _ in
                if value != nil {
                    mutable.removeAttribute(.backgroundColor, range: range)
                }
            }
        }

        let anchorOffsets = collectAnchorOffsets(mutable)
        let pageBackgroundImageSource = backgroundImageSource(ast)
        let pageBackgroundImage = await loadBackgroundImage(ast)
        if pageBackgroundImage != nil, mutable.length > 0 {
            mutable.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: mutable.length))
        }
        debugLog(mutable)

        return HTMLAttributedStringBuilder.RenderedContent(
            attributedString: CJKTypographyProcessor.apply(to: mutable),
            pageBackgroundImage: pageBackgroundImage,
            pageBackgroundImageSource: pageBackgroundImageSource,
            anchorOffsets: anchorOffsets
        )
    }
}
