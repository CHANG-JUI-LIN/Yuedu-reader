import CoreText
import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

/// Production root-cause trace for the two final 《诡秘之主》 correctness
/// defects. The marker keeps the real-book fixture out of ordinary test runs.
@MainActor
struct BrowserLayoutMysteriesCorrectnessTests {
    private static let bookPath = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《诡秘之主4》作者：爱潜水的乌贼.epub"
    private static let viewport = CGSize(width: 440, height: 956)
    private static let insets = UIEdgeInsets(top: 82, left: 24, bottom: 32, right: 24)

    @Test(
        "trace fragmented decoration and missing glyph production defects",
        .enabled(if: FileManager.default.fileExists(
            atPath: "/tmp/yuedu-run-mysteries-correctness"
        ))
    )
    func productionRootCauseTrace() async throws {
        let session = try await PublicationSession.open(
            sourceURL: URL(fileURLWithPath: Self.bookPath)
        )
        #expect(session.bookTitle == "诡秘之主")
        try await traceFragmentedDecoration(session: session)
        try await traceMissingGlyphs(session: session)
    }

    private func traceFragmentedDecoration(session: PublicationSession) async throws {
        let spine = 2
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = try await adapter.chapterHTML(at: spine)
        let css = await adapter.processedCSS(forChapter: spine)
        // Match the larger reader typography that makes this real authored box
        // span fragmentainers. This is still the production chapter and
        // production pipeline; only the user-controlled root font size differs.
        let config = makeConfig(fontResolver: adapter.fontResolver(), rootFontSize: 24)
        let document = BrowserLayoutDocument(html: html, cssTexts: css, config: config)
        let pipeline = try document.makeLayout(
            containerSize: Self.viewport,
            fragmentHeight: contentRect.height
        )
        let pages = try await document.renderPages(containerSize: Self.viewport)
        let target = try #require(findBox(in: pipeline.rootBox, className: "kuang2"))
        let targetRect = try #require(documentBorderRect(of: target, root: pipeline.rootBox))
        let descendantIDs = Set(allBoxes(in: target).map(\.debugNodeID))

        print("MYSTERIES_A chapter=\(session.chapters[spine].title) spine=\(spine) href=\(session.chapters[spine].href)")
        print("MYSTERIES_A authored selector=div.kuang2 display=\(target.style.display) width=\(target.style.width) height=\(target.style.height)")
        print("MYSTERIES_A authored margin=\(target.style.marginTop),\(target.style.marginRight),\(target.style.marginBottom),\(target.style.marginLeft) padding=\(target.style.paddingTop),\(target.style.paddingRight),\(target.style.paddingBottom),\(target.style.paddingLeft)")
        print("MYSTERIES_A authored border widths=\(target.style.borderTopWidth),\(target.style.borderRightWidth),\(target.style.borderBottomWidth),\(target.style.borderLeftWidth) styles=\(target.style.borderTopStyle),\(target.style.borderRightStyle),\(target.style.borderBottomStyle),\(target.style.borderLeftStyle) radius=\(target.style.borderRadius) background=\(String(describing: target.style.backgroundColor)) boxDecorationBreak=absent(default slice)")
        print("MYSTERIES_A layout marginBox=\(targetRect.insetBy(dx: -target.margins.left, dy: -target.margins.top)) borderBox=\(targetRect) paddingBox=\(inset(targetRect, target.borders)) contentBox=\(inset(inset(targetRect, target.borders), target.padding)) fullDocumentHeight=\(targetRect.height)")

        var productionFills: [FillFragment] = []
        for page in pages {
            let fills = allFillFragments(page.fragments).filter { $0.nodeID == target.debugNodeID }
            productionFills.append(contentsOf: fills)
            let text = BrowserLayoutTestSupport.allTextFragments([page]).filter {
                descendantIDs.contains($0.nodeID)
            }
            guard !fills.isEmpty || !text.isEmpty else { continue }
            let contentRange = union(text.map(\.sourceRange))
            print("MYSTERIES_A page=\(page.index) fragmentainer=\(contentRect) contentRange=\(String(describing: contentRange))")
            for fill in fills {
                print("MYSTERIES_A page=\(page.index) fill documentRect=\(fill.documentRect.rawValue) pageLocal=\(fill.rect.rawValue) edges=top:\(fill.borderTop.isVisible),right:\(fill.borderRight.isVisible),bottom:\(fill.borderBottom.isVisible),left:\(fill.borderLeft.isVisible) radius=\(fill.cornerRadius) exceedsContentBottom=\(fill.rect.maxY > contentRect.maxY + 0.001)")
            }
            let list = DisplayListBuilder.build(for: page, sourceText: document.lastSourceText)
            for item in list.items {
                if case .fill(let fill) = item, fill.nodeID == target.debugNodeID {
                    print("MYSTERIES_A page=\(page.index) displayFill rect=\(fill.rect.rawValue) fragmentPosition=\(fill.fragmentPosition) fullLayoutBoxRect=\(fill.rect.height == targetRect.height) rendererClip=fillRectOnly backgroundClip=fragmentAwarePath pageContentClip=fragmentRect")
                }
            }
        }
        #expect(productionFills.count >= 2)
        #expect(productionFills.allSatisfy {
            $0.rect.minY >= contentRect.minY - 0.001
                && $0.rect.maxY <= contentRect.maxY + 0.001
        })
        #expect(productionFills.first?.fragmentPosition == .first)
        #expect(productionFills.last?.fragmentPosition == .last)
    }

    private func traceMissingGlyphs(session: PublicationSession) async throws {
        let spine = 4
        let fontResponse = try await session.response(
            for: session.resourceURL(for: "OEBPS/Fonts/jj.ttf")
        )
        let provider = try #require(CGDataProvider(data: fontResponse.data as CFData))
        let cgFont = try #require(CGFont(provider))
        let sourceFont = CTFontCreateWithGraphicsFont(cgFont, 12, nil, nil)
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let html = try await adapter.chapterHTML(at: spine)
        let css = await adapter.processedCSS(forChapter: spine)
        let resolver = adapter.fontResolver()
        let config = makeConfig(fontResolver: resolver)

        let dom = try SwiftSoup.parse(html)
        let h1 = try #require(try dom.select("h1.fmhG1").first())
        let span = try #require(try dom.select("span.fmsG1").first())
        printSource("百科全书", label: "MYSTERIES_B source-h1")
        printSource("丨人物志丨", label: "MYSTERIES_B source-span")
        print("MYSTERIES_B DOM h1Own=\(h1.ownText()) h1Text=\((try? h1.text()) ?? "") spanText=\((try? span.text()) ?? "")")

        var metrics = LayoutMetrics()
        let styleRoot = try LegacyCSSFrontend().buildStyleTree(
            html: html,
            cssTexts: css,
            config: config,
            metrics: &metrics
        ).rootNode
        let h1Node = try #require(findStyleNode(in: styleRoot, className: "fmhG1"))
        let spanNode = try #require(findStyleNode(in: styleRoot, className: "fmsG1"))
        printComputedStyle(h1Node, label: "MYSTERIES_B computed-h1", resolver: resolver)
        printComputedStyle(spanNode, label: "MYSTERIES_B computed-span", resolver: resolver)

        let document = BrowserLayoutDocument(html: html, cssTexts: css, config: config)
        let pages = try await document.renderPages(containerSize: Self.viewport)
        print("MYSTERIES_B browser sourceText=\(document.lastSourceText.debugDescription)")
        for target in ["百科全书", "丨人物志丨"] {
            let range = (document.lastSourceText as NSString).range(of: target)
            print("MYSTERIES_B browser target=\(target) sourceRange=\(range)")
            let fragments = BrowserLayoutTestSupport.allTextFragments(pages).filter {
                NSIntersectionRange($0.sourceRange, range).length > 0
            }
            var seenLines = Set<ObjectIdentifier>()
            for fragment in fragments {
                print("MYSTERIES_B fragment target=\(target) text=\(sourceSlice(document.lastSourceText, fragment.sourceRange)) font=\(fragment.font.fontName) rect=\(fragment.rect.rawValue) sourceRange=\(fragment.sourceRange) shaped=\(fragment.sourceMapping)")
                if let line = fragment.ctLine {
                    let id = ObjectIdentifier(line)
                    if seenLines.insert(id).inserted {
                        printCTLine(line, label: "MYSTERIES_B shaped target=\(target)")
                        #expect(!hasMissingPhysicalGlyph(in: line))
                    }
                }
                #expect(fontCovers(target, font: fragment.font))
                #expect(
                    glyphIDs(target, font: fragment.font as CTFont)
                        == glyphIDs(target, font: sourceFont)
                )
            }
            for page in pages {
                let list = DisplayListBuilder.build(for: page, sourceText: document.lastSourceText)
                for item in list.items {
                    guard case .text(let text) = item,
                          NSIntersectionRange(text.sourceRange, range).length > 0 else { continue }
                    print("MYSTERIES_B display target=\(target) text=\(text.text) font=\(text.font.fontName) glyphs=\(glyphDump(text.text, font: text.font)) ctLineRetained=\(text.ctLine != nil) painter=reshapesSingleFont")
                    #expect(fontCovers(text.text, font: text.font))
                }
            }
        }

        let settings = ReaderRenderSettings(
            theme: "paper",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 17,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 24,
            marginV: 82,
            footerHeight: 0,
            contentInsets: Self.insets
        )
        let legacy = try await EPUBAttributedStringBuilder(
            session: session,
            renderSize: Self.viewport
        ).buildChapter(
            at: spine,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        ).attributedString
        for target in ["百科全书", "丨人物志丨"] {
            let range = (legacy.string as NSString).range(of: target)
            print("MYSTERIES_B legacy target=\(target) range=\(range)")
            guard range.location != NSNotFound else { continue }
            legacy.enumerateAttribute(.font, in: range) { value, subrange, _ in
                if let font = value as? UIFont {
                    print("MYSTERIES_B legacy font=\(font.fontName) range=\(subrange) glyphs=\(glyphDump(sourceSlice(legacy.string, subrange), font: font))")
                }
            }
        }
    }

    private var contentRect: CGRect {
        CGRect(
            x: Self.insets.left,
            y: Self.insets.top,
            width: Self.viewport.width - Self.insets.left - Self.insets.right,
            height: Self.viewport.height - Self.insets.top - Self.insets.bottom
        )
    }

    private func makeConfig(
        fontResolver: (([String], Int, Bool, CGFloat) -> UIFont?)?,
        rootFontSize: CGFloat = 17
    ) -> BrowserLayoutConfig {
        BrowserLayoutConfig(
            renderWidth: contentRect.width,
            renderHeight: contentRect.height,
            rootFontSize: rootFontSize,
            fontFamilies: [],
            textColor: .black,
            backgroundColor: .white,
            contentInsets: Self.insets,
            lineHeight: nil,
            fontResolver: fontResolver
        )
    }

    private func findBox(in box: BlockBox, className: String) -> BlockBox? {
        if box.debugClasses.contains(className) { return box }
        for child in box.children {
            if let match = findBox(in: child, className: className) { return match }
        }
        return nil
    }

    private func allBoxes(in box: BlockBox) -> [BlockBox] {
        [box] + box.children.flatMap(allBoxes)
    }

    private func documentBorderRect(of target: BlockBox, root: BlockBox) -> CGRect? {
        let rootContent = CGPoint(x: 0, y: root.margins.top)
        func walk(_ box: BlockBox, contentOrigin: CGPoint) -> CGRect? {
            let border = CGRect(
                x: contentOrigin.x - box.borders.left - box.padding.left,
                y: contentOrigin.y - box.borders.top - box.padding.top,
                width: box.frame.width,
                height: box.frame.height
            )
            if box === target { return border }
            for child in box.children {
                let childContent = CGPoint(
                    x: contentOrigin.x + child.frame.minX + child.borders.left + child.padding.left,
                    y: contentOrigin.y + child.frame.minY + child.borders.top + child.padding.top
                )
                if let match = walk(child, contentOrigin: childContent) { return match }
            }
            return nil
        }
        return walk(root, contentOrigin: rootContent)
    }

    private func inset(_ rect: CGRect, _ edges: EdgeSizes) -> CGRect {
        CGRect(
            x: rect.minX + edges.left,
            y: rect.minY + edges.top,
            width: max(0, rect.width - edges.horizontal),
            height: max(0, rect.height - edges.vertical)
        )
    }

    private func allFillFragments(_ fragments: [Fragment]) -> [FillFragment] {
        fragments.flatMap { fragment -> [FillFragment] in
            switch fragment {
            case .fill(let fill): return [fill]
            case .group(let children): return allFillFragments(children)
            default: return []
            }
        }
    }

    private func union(_ ranges: [NSRange]) -> NSRange? {
        let visible = ranges.filter { $0.length > 0 }
        guard let first = visible.first else { return nil }
        return visible.dropFirst().reduce(first, NSUnionRange)
    }

    private func findStyleNode(
        in node: ComputedStyleNode,
        className: String
    ) -> ComputedStyleNode? {
        if let element = node.element,
           ((try? element.classNames().contains(className)) == true) {
            return node
        }
        for child in node.children {
            if case .element(let element) = child,
               let match = findStyleNode(in: element, className: className) {
                return match
            }
        }
        return nil
    }

    private func printComputedStyle(
        _ node: ComputedStyleNode,
        label: String,
        resolver: (([String], Int, Bool, CGFloat) -> UIFont?)?
    ) {
        let style = node.style
        let primary = InlineLayout.resolvedFont(for: style, resolver: resolver)
        let rawNamed = UIFont(name: primary.fontName, size: primary.pointSize)
        let probe = "百科全书丨人物志丨"
        let rawNamedGlyphs = rawNamed.map { glyphDump(probe, font: $0) } ?? "nil"
        let cascade = (CTFontCopyDefaultCascadeListForLanguages(primary as CTFont, nil) as? [CTFontDescriptor] ?? [])
            .prefix(8)
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        print("\(label) node=\(node.nodeID) families=\(style.fontFamilies) size=\(style.fontSize) weight=\(style.fontWeight) italic=\(style.isItalic) inherited=true resolved=\(primary.fontName) cascade=\(cascade)")
        print("\(label) descriptor=\(primary.fontDescriptor.fontAttributes) primaryGlyphs=\(glyphDump(probe, font: primary)) rawNamedGlyphs=\(rawNamedGlyphs)")
    }

    private func printSource(_ text: String, label: String) {
        let scalars = text.unicodeScalars.map { String(format: "U+%04X", $0.value) }
        let bytes = text.utf8.map { String(format: "%02X", $0) }
        print("\(label) string=\(text.debugDescription) scalars=\(scalars) utf8=\(bytes) replacement=\(text.contains("\u{FFFD}"))")
    }

    private func printCTLine(_ line: CTLine, label: String) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let range = CTRunGetStringRange(run)
            let count = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName] as! CTFont
            let name = CTFontCopyPostScriptName(font) as String
            print("\(label) range=\(range.location):\(range.length) font=\(name) glyphs=\(glyphs) notdef=\(glyphs.enumerated().filter { $0.element == 0 }.map(\.offset))")
        }
    }

    private func glyphDump(_ text: String, font: UIFont) -> String {
        var characters = Array(text.utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        let covered = CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count)
        return "covered=\(covered) ids=\(glyphs) notdef=\(glyphs.enumerated().filter { $0.element == 0 }.map(\.offset))"
    }

    private func fontCovers(_ text: String, font: UIFont) -> Bool {
        var characters = Array(text.utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        return CTFontGetGlyphsForCharacters(
            font as CTFont,
            &characters,
            &glyphs,
            characters.count
        ) && glyphs.allSatisfy { $0 != 0 }
    }

    private func glyphIDs(_ text: String, font: CTFont) -> [CGGlyph] {
        var characters = Array(text.utf16)
        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        _ = CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        return glyphs
    }

    private func hasMissingPhysicalGlyph(in line: CTLine) -> Bool {
        (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
            let count = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            let name = (CTFontCopyPostScriptName(font) as String).lowercased()
            return name.contains("lastresort") || glyphs.contains(0)
        }
    }

    private func sourceSlice(_ source: String, _ range: NSRange) -> String {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.location + range.length <= (source as NSString).length else { return "" }
        return (source as NSString).substring(with: range)
    }
}
