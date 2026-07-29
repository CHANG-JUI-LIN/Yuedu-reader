import Foundation
import SwiftSoup
import UIKit
import YueduCoreText

final class HTMLBuilderDOMParser {
    func parse(
        html: String,
        collectStyles: @escaping (Document) async -> [String]
    ) async -> HTMLAttributedStringBuilder.ParsedHTML? {
        let parsedDOM: (document: Document, body: Element)? = ReaderPerfTrace.span(
            .htmlParse,
            metadata: ReaderPerfMetadata(
                characterCount: html.utf16.count,
                executor: Thread.isMainThread ? "main" : "background"
            )
        ) {
            // SwiftSoup.parse degrades to a hang on the ~275KB of inline base64 SVG a 段評-heavy 起点
            // chapter carries. Lift the opaque base64 payloads out, parse the slimmed structure, then
            // restore them in the DOM so the AST sees full data URIs. No-op when there are none.
            let (slimmed, payloadRestore) = ReaderHTMLUtilities.extractDataURIPayloads(html)
            guard let document = try? SwiftSoup.parse(slimmed),
                  let body = document.body() else {
                return nil
            }
            ReaderHTMLUtilities.restoreDataURIPayloads(in: document, restore: payloadRestore)
            return (document, body)
        }
        guard let parsedDOM else {
            return nil
        }

        let stylesheetTexts = await collectStyles(parsedDOM.document)
        let cssParseTrace = ReaderPerfTrace.begin(
            .cssParse,
            metadata: ReaderPerfMetadata(
                characterCount: stylesheetTexts.reduce(0) { $0 + $1.utf16.count },
                executor: Thread.isMainThread ? "main" : "background"
            )
        )
        var regularRules: [CSSRule] = []
        var firstLetterRules: [CSSRule] = []
        for (index, css) in stylesheetTexts.enumerated() {
            let (reg, fl) = CSSParser.parseWithFirstLetter(css: css, orderOffset: index * 10_000)
            regularRules.append(contentsOf: reg)
            firstLetterRules.append(contentsOf: fl)
        }
        ReaderPerfTrace.end(
            cssParseTrace,
            metadata: ReaderPerfMetadata(
                characterCount: stylesheetTexts.reduce(0) { $0 + $1.utf16.count },
                ruleCount: regularRules.count + firstLetterRules.count,
                executor: Thread.isMainThread ? "main" : "background"
            )
        )
        return HTMLAttributedStringBuilder.ParsedHTML(
            body: parsedDOM.body,
            rules: regularRules,
            firstLetterRules: firstLetterRules
        )
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
        let cssMatchTrace = ReaderPerfTrace.begin(
            .cssMatch,
            metadata: ReaderPerfMetadata(
                ruleCount: parsed.rules.count + parsed.firstLetterRules.count,
                writingMode: String(describing: config.writingMode),
                executor: Thread.isMainThread ? "main" : "background"
            )
        )
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
        let root = HTMLAttributedStringBuilder.ElementNode(
            tag: "body",
            id: parsed.body.id(),
            classes: Array((try? parsed.body.classNames()) ?? []),
            attributes: makeAttributeMap(parsed.body),
            resolvedStyle: bodyStyle,
            children: astChildren
        )
        ReaderPerfTrace.end(
            cssMatchTrace,
            metadata: ReaderPerfMetadata(
                ruleCount: parsed.rules.count + parsed.firstLetterRules.count,
                writingMode: String(describing: config.writingMode),
                executor: Thread.isMainThread ? "main" : "background"
            )
        )
        return root
    }
}
