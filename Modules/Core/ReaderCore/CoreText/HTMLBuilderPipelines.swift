import Foundation
import SwiftSoup
import UIKit
import YueduCoreText

/// Publication-scoped cache for immutable CSS parse results. The processed stylesheet text is
/// already cached by the EPUB/online resource builders; this second layer avoids reparsing the
/// same rules every time a new chapter creates an HTMLAttributedStringBuilder.
///
/// **Accessed from more than one thread, so the dictionary is locked.** One instance is held by
/// the `@MainActor` `EPUBAttributedStringBuilder` / `OnlineProviderAttributedStringBuilder` and
/// shared by every chapter that builder produces. `buildStyledAST` and `HTMLBuilderDOMParser.parse`
/// are nonisolated `async`, so awaiting them from the main actor hops to the concurrent executor —
/// and while one chapter build is suspended there, `ChapterDocumentStore` is free to start the
/// next one. Two adjacent chapters preloading at once therefore reach this dictionary on two
/// threads. Unsynchronised, that is a `Dictionary` being resized under a concurrent read: a real
/// device sent back a SIGSEGV inside `parsedStylesheet` from exactly that stack.
final class HTMLStylesheetCache: @unchecked Sendable {
    /// Immutable once built, so handing the same instance to several threads is safe.
    final class ParsedStylesheet {
        let regularRules: [CSSRule]
        let firstLetterRules: [CSSRule]

        init(regularRules: [CSSRule], firstLetterRules: [CSSRule]) {
            self.regularRules = regularRules
            self.firstLetterRules = firstLetterRules
        }
    }

    private let lock = NSLock()
    private var entries: [String: ParsedStylesheet] = [:]

    func parsedStylesheet(css: String, orderOffset: Int) -> ParsedStylesheet {
        let key = "\(orderOffset)|\(css)"
        if let cached = lock.withLock({ entries[key] }) {
            return cached
        }

        // Parsed outside the lock deliberately. CSS parsing is the dominant cost of building a
        // chapter on a stylesheet-heavy book, and holding the lock across it would serialise
        // every concurrent chapter build behind whichever one got here first — undoing the
        // reason chapters are preloaded in parallel at all.
        //
        // The cost is that two threads can parse the same stylesheet at the same time. That is
        // harmless: `CSSParser` is an `enum` of pure functions with no shared state, and
        // `ParsedStylesheet` is immutable, so the two results are interchangeable.
        let parsed = CSSParser.parseWithFirstLetter(css: css, orderOffset: orderOffset)
        let result = ParsedStylesheet(
            regularRules: parsed.regular,
            firstLetterRules: parsed.firstLetter
        )

        return lock.withLock {
            // Whoever landed first wins, so a given key always resolves to one shared instance
            // and callers can compare rule identity.
            if let winner = entries[key] {
                return winner
            }
            entries[key] = result
            return result
        }
    }
}

final class HTMLBuilderDOMParser {
    func parse(
        html: String,
        collectStyles: @escaping (Document) async -> [String],
        stylesheetCache: HTMLStylesheetCache? = nil
    ) async -> HTMLAttributedStringBuilder.ParsedHTML? {
        let htmlParseStart = SourcePerfTrace.now
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
        SourcePerfTrace.record(
            "coreText.document.htmlParse",
            "\(ReaderDocumentTrace.spineTag)html=\(html.utf16.count) ok=\(parsedDOM != nil)",
            since: htmlParseStart,
            thresholdMs: 0
        )
        guard let parsedDOM else {
            return nil
        }

        // `collectStyles` is the caller's closure; its own `css.collect` line is emitted inside it.
        let stylesheetTexts = await collectStyles(parsedDOM.document)
        let cssParseStart = SourcePerfTrace.now
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
            if let stylesheetCache {
                let parsed = stylesheetCache.parsedStylesheet(
                    css: css,
                    orderOffset: index * 10_000
                )
                regularRules.append(contentsOf: parsed.regularRules)
                firstLetterRules.append(contentsOf: parsed.firstLetterRules)
            } else {
                let (reg, fl) = CSSParser.parseWithFirstLetter(
                    css: css,
                    orderOffset: index * 10_000
                )
                regularRules.append(contentsOf: reg)
                firstLetterRules.append(contentsOf: fl)
            }
        }
        // Split the dark `@media` palette out once here so the per-element cascade never has to
        // filter by flag. Dark rules resolve into a separate per-element style (see
        // HTMLAttributedStringBuilder.resolvedStyles); when there are none the dark pass is
        // skipped entirely and this costs nothing.
        let darkRules = regularRules.filter { $0.isDarkMedia }
        let lightRules = darkRules.isEmpty ? regularRules : regularRules.filter { !$0.isDarkMedia }
        ReaderPerfTrace.end(
            cssParseTrace,
            metadata: ReaderPerfMetadata(
                characterCount: stylesheetTexts.reduce(0) { $0 + $1.utf16.count },
                ruleCount: regularRules.count + firstLetterRules.count,
                executor: Thread.isMainThread ? "main" : "background"
            )
        )
        SourcePerfTrace.record(
            "coreText.document.cssParse",
            "\(ReaderDocumentTrace.spineTag)sheets=\(stylesheetTexts.count) "
                + "css=\(stylesheetTexts.reduce(0) { $0 + $1.utf16.count }) "
                + "rules=\(regularRules.count + firstLetterRules.count) "
                + "cached=\(stylesheetCache != nil)",
            since: cssParseStart,
            thresholdMs: 0
        )
        return HTMLAttributedStringBuilder.ParsedHTML(
            body: parsedDOM.body,
            rules: lightRules,
            darkRules: darkRules,
            firstLetterRules: firstLetterRules
        )
    }
}

final class HTMLBuilderStyleResolver {
    func buildAST(
        from parsed: HTMLAttributedStringBuilder.ParsedHTML,
        config: HTMLAttributedStringBuilder.Config,
        makeRootStyle: (HTMLAttributedStringBuilder.Config) -> HTMLAttributedStringBuilder.ResolvedStyle,
        resolveStyle: (Element, HTMLAttributedStringBuilder.ResolvedStyle, HTMLAttributedStringBuilder.ResolvedStyle?, [CSSRule], [CSSRule], CGFloat, Element?, HTMLAttributedStringBuilder.Config) -> (light: HTMLAttributedStringBuilder.ResolvedStyle, dark: HTMLAttributedStringBuilder.ResolvedStyle?),
        buildChildren: ([Node], HTMLAttributedStringBuilder.ResolvedStyle, HTMLAttributedStringBuilder.ResolvedStyle?, [CSSRule], [CSSRule], CGFloat, Element?, HTMLAttributedStringBuilder.Config) async -> [HTMLAttributedStringBuilder.ASTNode],
        makeAttributeMap: (Element) -> [String: String]
    ) async -> HTMLAttributedStringBuilder.ElementNode {
        let cssMatchStart = SourcePerfTrace.now
        let cssMatchTrace = ReaderPerfTrace.begin(
            .cssMatch,
            metadata: ReaderPerfMetadata(
                ruleCount: parsed.rules.count + parsed.firstLetterRules.count,
                writingMode: String(describing: config.writingMode),
                executor: Thread.isMainThread ? "main" : "background"
            )
        )
        let rootStyle = makeRootStyle(config)
        let resolved = resolveStyle(
            parsed.body,
            rootStyle,
            rootStyle,
            parsed.rules,
            parsed.darkRules,
            config.fontSize,
            nil,
            config
        )
        let bodyStyle = resolved.light
        let bodyDarkStyle = resolved.dark
        let astChildren = await buildChildren(
            parsed.body.getChildNodes(),
            bodyStyle,
            bodyDarkStyle,
            parsed.rules,
            parsed.darkRules,
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
            resolvedDarkStyle: bodyDarkStyle,
            children: astChildren
        )
        // Covers the whole recursive element walk: selector matching, cascade, and inline-style
        // resolution for every node. `buildChildren` is the caller's recursion, so a slow
        // number here is the style system, not the tree shape alone.
        SourcePerfTrace.record(
            "coreText.document.cssMatch",
            "\(ReaderDocumentTrace.spineTag)rules=\(parsed.rules.count + parsed.firstLetterRules.count) "
                + "topLevel=\(astChildren.count) writing=\(config.writingMode)",
            since: cssMatchStart,
            thresholdMs: 0
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
