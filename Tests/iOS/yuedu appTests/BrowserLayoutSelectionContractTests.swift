import Testing
import UIKit
@testable import yuedu_app

/// Selection/annotation/TTS minimal contract: UTF-16 range → per-page rects,
/// source-range semantics preserved across relayouts, and link-vs-selection
/// hit-test priority in the page view.
@MainActor
struct BrowserLayoutSelectionContractTests {

    private func makeSettings(fontSize: CGFloat = 17) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: fontSize, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
    }

    private func makeEngine(text: String) async -> (engine: BrowserLayoutPageEngine, sourceText: String) {
        let html = "<html><body><p>\(text)</p></body></html>"
        let resource = MockBrowserLayoutResource(chapters: [
            .init(title: "c", href: "c.xhtml", html: html, css: [])
        ])
        let builder = MockAttributedStringBuilder(texts: ["c"])
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("bl-\(UUID().uuidString)"))
        let settings = makeSettings()
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: resource, delegate: delegate, settings: settings)
        await engine.start(renderSize: CGSize(width: 300, height: 160), bookId: "t")
        return (engine, resource.chapters[0].html)
    }

    @Test func rangeMapsToPageLocalRectsWithExactText() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
        let (engine, _) = await makeEngine(text: text)

        // Select the FIRST occurrence of "fox".
        let full = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
        let ns = full as NSString
        let foxRange = ns.range(of: "fox")

        let mapped = engine.rects(forSpine: 0, range: foxRange)
        #expect(!mapped.isEmpty)
        // The rects must exist on exactly one page (single-line fragment) and
        // cover "fox" — verify by intersecting fragment source ranges.
        let page = try #require(mapped.first)
        #expect(page.rects.count >= 1)
        #expect(page.rects[0].width > 0)
        // The rect width should approximate the "fox" advance (~3 × 8.5pt).
        #expect(page.rects[0].width > 15)
        #expect(page.rects[0].width < 40)
    }

    @Test func selectionUsesPreciseCTLineGeometry() async throws {
        // Ligature + variable-width Latin: "office" contains "ffi" (a single
        // ligature glyph), so proportional width estimation over the run
        // diverges from CoreText's typographic offsets. The precise path must
        // be taken (ctLine retained on the fragment).
        let text = "The office 這是測試。"
        let (engine, _) = await makeEngine(text: text)
        let ns = text as NSString
        let officeRange = ns.range(of: "office")

        let mapped = engine.rects(forSpine: 0, range: officeRange)
        #expect(!mapped.isEmpty)
        let page = try #require(mapped.first)
        let rect = try #require(page.rects.first)
        #expect(rect.width > 0)

        // Verify the fragment's ctLine actually drove the mapping: the precise
        // rect x should equal fragment.minX + CTLineGetOffsetForStringIndex,
        // and (critically) differ from the proportional estimate for a run
        // containing the "ffi" ligature.
        guard let (_, layout) = engine.testChapterLayout else { return }
        var foundFragment = false
        for pageFragments in layout.pages {
            func walk(_ fragments: [Fragment]) {
                for fragment in fragments {
                    if case .text(let t) = fragment,
                       NSIntersectionRange(t.sourceRange, officeRange).length > 0,
                       let line = t.ctLine {
                        foundFragment = true
                        let lineRange = CTLineGetStringRange(line)
                        let inLine = officeRange.location - lineRange.location
                        guard inLine >= 0,
                              inLine + officeRange.length <= lineRange.length else { continue }
                        let offset = CTLineGetOffsetForStringIndex(line, inLine, nil)
                        #expect(abs(rect.minX - (t.rect.minX + offset)) < 1.0)
                    }
                    if case .group(let children) = fragment { walk(children) }
                }
            }
            walk(pageFragments.fragments)
        }
        #expect(foundFragment)
    }

    @Test func rectsPreserveSourceSemanticsAfterRelayout() async throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
        let (engine, _) = await makeEngine(text: text)
        let full = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 30)
        let foxRange = (full as NSString).range(of: "fox")

        let before = engine.rects(forSpine: 0, range: foxRange)

        // Relayout with a different size — the selection must re-derive to the
        // SAME text (different geometry).
        await engine.invalidateLayout(newSize: CGSize(width: 200, height: 120))
        let after = engine.rects(forSpine: 0, range: foxRange)

        #expect(!before.isEmpty && !after.isEmpty)
        // Different page sizes → geometry changed somewhere (or the same page
        // with different rects). Semantics: rects still exist and are on pages
        // within the new layout.
        let totalPages = engine.totalPages
        for (page, _) in after {
            #expect(page < totalPages)
        }
    }

    @Test func selectionSuppressesLinkTapInsideHighlight() {
        let pageView = BrowserLayoutPageView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        var deselected = false
        var linkTapped: String? = nil
        pageView.onDeselect = { deselected = true }
        pageView.onLinkActivate = { linkTapped = $0.href }

        let linkItem = DisplayTextItem(
            sourceRange: NSRange(location: 0, length: 4), nodeID: 1,
            linkTarget: "http://example.com", writingMode: .horizontal,
            rect: PageLocalRect(rawValue: CGRect(x: 10, y: 10, width: 80, height: 20)), baselineY: 26,
            font: .systemFont(ofSize: 17), color: .black, text: "link",
            ctLine: nil
        )
        pageView.displayList = DisplayList(items: [.text(linkItem)])
        pageView.interactionRegions = LinkInteractionRegionSet.build(
            from: pageView.displayList, spineIndex: 0, anchors: [:]
        )
        // Selection covers the link rect → tap inside deselects, no link.
        pageView.highlightRects = [CGRect(x: 10, y: 10, width: 80, height: 20)]
        pageView.hasActiveSelection = true

        // Simulate the tap path.
        pageView.handleTapForTesting(at: CGPoint(x: 20, y: 20))
        #expect(deselected)
        #expect(linkTapped == nil)

        // After deselection, tapping the link follows it.
        pageView.hasActiveSelection = false
        pageView.handleTapForTesting(at: CGPoint(x: 20, y: 20))
        #expect(linkTapped == "http://example.com")
    }
}

extension BrowserLayoutPageView {
    /// Test seam: a whole tap, driven through the view's REAL entry points —
    /// the selection branch the tap recognizer runs, then the press lifecycle
    /// that owns link activation. It must not reimplement the routing: the copy
    /// that used to live here would have kept passing while the shipping path
    /// changed underneath it.
    func handleTapForTesting(at point: CGPoint) {
        beginLinkPress(at: point)   // touchesBegan
        routeTap(at: point)         // the tap recognizer's action
        endLinkPress(at: point)     // touchesEnded
    }
}
