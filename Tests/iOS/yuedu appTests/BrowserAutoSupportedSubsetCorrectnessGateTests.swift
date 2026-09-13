@testable import YueduCoreText
import Testing
import SwiftSoup
import UIKit
@testable import yuedu_app

/// BrowserAuto supported-subset gate: reader viewport policy must bound the
/// root containing block before authored body geometry is applied.
@MainActor
struct BrowserAutoSupportedSubsetCorrectnessGateTests {
    private static let viewport = CGSize(width: 440, height: 956)
    private static let insets = UIEdgeInsets(top: 82, left: 24, bottom: 32, right: 24)

    private func render(_ bodyStyle: String? = nil) async throws -> (
        pages: [PageFragments],
        pipeline: BrowserLayoutDocument.BrowserLayoutPipelineResult
    ) {
        let styleAttribute = bodyStyle.map { #" style="\#($0)""# } ?? ""
        let html = """
        <html><head><style>
          p { margin: 0; padding: 0; }
        </style></head>
        <body\(styleAttribute)><p>普通正文用來驗證根 containing block 與讀者頁面留白。</p></body></html>
        """
        let config = BrowserLayoutConfig(
            renderWidth: Self.viewport.width - Self.insets.left - Self.insets.right,
            renderHeight: Self.viewport.height - Self.insets.top - Self.insets.bottom,
            rootFontSize: 17,
            fontFamilies: ["PingFangSC-Regular"],
            textColor: .black,
            backgroundColor: .white,
            contentInsets: Self.insets
        )
        let document = BrowserLayoutDocument(html: html, cssTexts: [], config: config)
        let pipeline = try document.makeLayout(
            containerSize: Self.viewport,
            fragmentHeight: config.renderHeight
        )
        let pages = try await document.renderPages(containerSize: Self.viewport)
        return (pages, pipeline)
    }

    @Test func symmetricReaderInsetsRemainSymmetricAroundDefaultBodyMargins() async throws {
        let result = try await render()
        let root = result.pipeline.rootBox
        let first = try #require(BrowserLayoutTestSupport.allTextFragments(result.pages).first)

        // UA body margin is 8px on each side. It lives inside the reader's
        // symmetric 24pt page inset, never entirely on the right edge.
        #expect(abs(root.margins.left - 8) < 0.01)
        #expect(abs(root.margins.right - 8) < 0.01)
        #expect(abs(root.contentSize.width - 376) < 0.01)
        #expect(abs(first.rect.minX - 32) < 0.5)
        #expect(abs((Self.viewport.width - (first.rect.minX + root.contentSize.width)) - 32) < 0.5)
    }

    @Test func authoredAsymmetricBodyMarginsRemainAsymmetricInsideReaderInsets() async throws {
        let result = try await render("margin:0 30px 0 10px;padding:0")
        let root = result.pipeline.rootBox
        let first = try #require(BrowserLayoutTestSupport.allTextFragments(result.pages).first)

        #expect(abs(root.margins.left - 10) < 0.01)
        #expect(abs(root.margins.right - 30) < 0.01)
        #expect(abs(root.contentSize.width - 352) < 0.01)
        #expect(abs(first.rect.minX - 34) < 0.5)
        #expect(abs((Self.viewport.width - (first.rect.minX + root.contentSize.width)) - 54) < 0.5)
    }

    @Test func zeroRootSideInsetsPreserveTheExistingFragmentOrigin() async throws {
        let result = try await render("margin:0;padding:0")
        let root = result.pipeline.rootBox
        let first = try #require(BrowserLayoutTestSupport.allTextFragments(result.pages).first)

        #expect(abs(root.contentSize.width - 392) < 0.01)
        #expect(abs(first.rect.minX - 24) < 0.5)
        #expect(abs((Self.viewport.width - (first.rect.minX + root.contentSize.width)) - 24) < 0.5)
    }

    @Test(
        "audit production BrowserAuto decisions for Hongwu chapters",
        .enabled(if: FileManager.default.fileExists(
            atPath: "/tmp/yuedu-run-browser-auto-correctness-gate"
        ))
    )
    func productionHongwuScannerAudit() async throws {
        try await auditAllPowerProseGeometry()

        let sourceURL = URL(fileURLWithPath:
            "/Users/zhangruilin/Desktop/Test document/EPUB Format/壹▪洪武大帝.epub"
        )
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        print(
            "AUTO_GATE publication title=\(session.bookTitle) chapters=\(session.chapters.count) "
                + "layout=\(session.layoutMode.rawValue) writing=\(session.epubWritingMode.rawValue) "
                + "progression=\(session.pageProgressionDirection.rawValue)"
        )

        var targets = session.chapters.filter {
            ["扉页", "制作说明", "目录", "我们从一份档案开始"].contains($0.title)
        }
        if !targets.contains(where: { $0.title == "我们从一份档案开始" }) {
            for chapter in session.chapters where !targets.contains(where: { $0.index == chapter.index }) {
                let html = try await adapter.chapterHTML(at: chapter.index)
                guard let document = try? SwiftSoup.parse(html),
                      let bodyText = try? document.body()?.text(),
                      bodyText.contains("我们从一份档案开始") else { continue }
                targets.append(chapter)
            }
        }
        targets.sort { $0.index < $1.index }

        for chapter in targets {
            let html = try await adapter.chapterHTML(at: chapter.index)
            let css = await adapter.processedCSS(forChapter: chapter.index)
            let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
            let document = try SwiftSoup.parse(html)
            let counts = semanticCounts(in: document)
            print(
                "AUTO_GATE case title=\(chapter.title.debugDescription) spine=\(chapter.index) "
                    + "href=\(chapter.href) publicationLayout=\(session.layoutMode.rawValue) "
                    + "spineLayout=\(chapter.layoutModeOverride?.rawValue ?? "inherit") "
                    + "decision=\(scan.supported ? "browser" : "legacy-fallback") "
                    + "reasons=\(scan.unsupportedFeatures.map(\.description).joined(separator: ",")) "
                    + "DOM=\(counts)"
            )
            printSemanticMarkup(in: document, chapter: chapter)
            printMatchedLayoutDeclarations(in: document, cssTexts: css, chapter: chapter)
        }

        #expect(targets.contains { $0.title == "扉页" })
        #expect(targets.contains { $0.title == "制作说明" })
        #expect(targets.contains { $0.title == "目录" })
        #expect(targets.contains { $0.title == "第一章 童年" })
    }

    private func auditAllPowerProseGeometry() async throws {
        let sourceURL = URL(fileURLWithPath:
            "/Users/zhangruilin/Desktop/Test document/EPUB Format/《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub"
        )
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        var candidate: (
            chapter: PublicationChapterDescriptor,
            html: String,
            css: [String],
            scan: BrowserLayoutCapabilityResult
        )?
        for chapter in session.chapters.prefix(120) {
            let html = try await adapter.chapterHTML(at: chapter.index)
            guard let document = try? SwiftSoup.parse(html),
                  ((try? document.select("p").size()) ?? 0) >= 2,
                  ((try? document.select("table").isEmpty()) ?? false),
                  let body = document.body(),
                  ((try? body.text().count) ?? 0) >= 200 else { continue }
            let css = await adapter.processedCSS(forChapter: chapter.index)
            let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
            guard scan.supported else { continue }
            candidate = (chapter, html, css, scan)
            break
        }
        let prose = try #require(candidate)
        let config = BrowserLayoutConfig(
            renderWidth: Self.viewport.width - Self.insets.left - Self.insets.right,
            renderHeight: Self.viewport.height - Self.insets.top - Self.insets.bottom,
            rootFontSize: 17,
            fontFamilies: [],
            textColor: .black,
            backgroundColor: .white,
            contentInsets: Self.insets,
            lineHeight: 1.4,
            fontResolver: adapter.fontResolver()
        )
        let document = BrowserLayoutDocument(
            html: prose.html,
            cssTexts: prose.css,
            config: config
        )
        let pipeline = try document.makeLayout(
            containerSize: Self.viewport,
            fragmentHeight: config.renderHeight
        )
        let root = pipeline.rootBox
        let rootContentX = Self.insets.left
            + root.margins.left + root.borders.left + root.padding.left
        let rootContentRight = Self.viewport.width
            - (rootContentX + root.contentSize.width)
        let lineBox = firstProseLineBox(in: root) ?? firstLineBox(in: root)
        let pageContentRect = CGRect(
            x: Self.insets.left,
            y: Self.insets.top,
            width: config.renderWidth,
            height: config.renderHeight
        )
        let ifcDescription = lineBox.map {
            let first = $0.lines.first?.contentX ?? -1
            let subsequent = $0.lines.dropFirst().first?.contentX ?? -1
            return "contentWidth=\($0.contentSize.width),firstContentX=\(first),subsequentContentX=\(subsequent)"
        } ?? "none"
        print(
            "AUTO_GATE prose title=\(session.bookTitle) chapter=\(prose.chapter.title.debugDescription) "
                + "spine=\(prose.chapter.index) href=\(prose.chapter.href) "
                + "decision=\(prose.scan.supported ? "browser" : "legacy-fallback") "
                + "viewport=\(Self.viewport) readerInsets=\(Self.insets) "
                + "pageContentRect=\(pageContentRect) "
                + "browserViewport=\(Self.viewport) rootContainingWidth=\(pipeline.contentSize.width) "
                + "bodyMargins=\(root.margins) bodyPadding=\(root.padding) "
                + "bodyBorders=\(root.borders) bodyContentRect=(x:\(rootContentX),"
                + "width:\(root.contentSize.width),rightInset:\(rootContentRight)) "
                + "IFC=\(ifcDescription)"
        )
        #expect(prose.scan.supported)
        #expect(abs(rootContentX - rootContentRight) < 0.01)
    }

    private func firstLineBox(in root: BlockBox) -> BlockBox? {
        if !root.lines.isEmpty { return root }
        for child in root.children {
            if let match = firstLineBox(in: child) { return match }
        }
        return nil
    }

    private func firstProseLineBox(in root: BlockBox) -> BlockBox? {
        if root.debugTag == "p", root.lines.count >= 2 { return root }
        for child in root.children {
            if let match = firstProseLineBox(in: child) { return match }
        }
        return nil
    }

    private func semanticCounts(in document: Document) -> String {
        func count(_ selector: String) -> Int {
            (try? document.select(selector).size()) ?? 0
        }
        return [
            "table=\(count("table"))", "tr=\(count("tr"))",
            "td=\(count("td"))", "th=\(count("th"))",
            "svg=\(count("svg"))", "img=\(count("img"))",
            "inlineStyle=\(count("[style]"))",
        ].joined(separator: ";")
    }

    private func printSemanticMarkup(
        in document: Document,
        chapter: PublicationChapterDescriptor
    ) {
        let elements = (try? document.select("table, tr, td, th, [style]").array()) ?? []
        for element in elements.prefix(24) {
            let markup = ((try? element.outerHtml()) ?? "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            print(
                "AUTO_GATE DOM spine=\(chapter.index) element=\(elementDescriptor(element)) "
                    + "parentChain=\(parentChain(element)) markup=\(String(markup.prefix(420)))"
            )
        }
    }

    private func printMatchedLayoutDeclarations(
        in document: Document,
        cssTexts: [String],
        chapter: PublicationChapterDescriptor
    ) {
        let interesting = Set([
            "display", "position", "float", "clear", "width", "height",
            "min-width", "max-width", "min-height", "max-height",
            "margin", "margin-left", "margin-right", "margin-top", "margin-bottom",
            "padding", "padding-left", "padding-right", "padding-top", "padding-bottom",
            "top", "right", "bottom", "left", "transform", "transform-origin",
            "writing-mode", "-webkit-writing-mode", "-epub-writing-mode",
            "flex", "flex-direction", "flex-wrap", "justify-content", "align-items",
            "grid", "grid-template-columns", "grid-template-rows", "gap",
            "background", "background-image", "background-size", "background-position",
        ])
        let elements = (try? document.getAllElements().array()) ?? []
        let fullCSS = cssTexts + LegacyCSSFrontendSupport.inlineStyles(in: document)
        var emitted = Set<String>()
        for rule in LegacyCSSFrontendSupport.parseRules(in: fullCSS) {
            let matched = elements.filter {
                rule.selector.matches(element: $0, parent: $0.parent())
            }
            guard !matched.isEmpty else { continue }
            for property in rule.declarationOrder where interesting.contains(property) {
                let normal = rule.declarations[property]
                let important = rule.importantDeclarations[property]
                guard let value = important ?? normal else { continue }
                for element in matched.prefix(8) {
                    let key = "\(selectorText(rule.selector))|\(elementDescriptor(element))|\(property)|\(value)|\(important != nil)"
                    guard emitted.insert(key).inserted else { continue }
                    print(
                        "AUTO_GATE CSS spine=\(chapter.index) selector=\(selectorText(rule.selector)) "
                            + "specificity=\(rule.specificity) order=\(rule.order) "
                            + "element=\(elementDescriptor(element)) parentChain=\(parentChain(element)) "
                            + "declaration=\(property):\(value) important=\(important != nil)"
                    )
                }
            }
        }
        for element in (try? document.select("[style]").array()) ?? [] {
            let style = (try? element.attr("style")) ?? ""
            print(
                "AUTO_GATE INLINE spine=\(chapter.index) element=\(elementDescriptor(element)) "
                    + "parentChain=\(parentChain(element)) style=\(style)"
            )
        }
    }

    private func elementDescriptor(_ element: Element) -> String {
        let id = element.id().isEmpty ? "" : "#\(element.id())"
        let classes = ((try? element.classNames().sorted()) ?? [])
            .map { ".\($0)" }.joined()
        return "<\(element.tagName())\(id)\(classes)>"
    }

    private func parentChain(_ element: Element) -> String {
        var chain: [String] = []
        var current: Element? = element
        while let node = current, chain.count < 8 {
            chain.append(elementDescriptor(node))
            current = node.parent()
        }
        return chain.joined(separator: " <- ")
    }

    private func selectorText(_ selector: CSSSelector) -> String {
        selector.components.enumerated().map { index, component in
            var text = component.tag ?? "*"
            if let id = component.id { text += "#\(id)" }
            for name in component.classes.sorted() { text += ".\(name)" }
            for attribute in component.attributes {
                let op: String
                switch attribute.op {
                case .exists: op = ""
                case .equals: op = "="
                case .includes: op = "~="
                case .dashMatch: op = "|="
                case .prefix: op = "^="
                case .suffix: op = "$="
                case .substring: op = "*="
                }
                text += op.isEmpty
                    ? "[\(attribute.name)]"
                    : "[\(attribute.name)\(op)\(attribute.value)]"
            }
            if component.firstChild { text += ":first-child" }
            guard index > 0 else { return text }
            let combinator: String
            switch component.combinator {
            case .child: combinator = " > "
            case .descendant: combinator = " "
            case .adjacentSibling: combinator = " + "
            case .generalSibling: combinator = " ~ "
            }
            return combinator + text
        }.joined()
    }
}
