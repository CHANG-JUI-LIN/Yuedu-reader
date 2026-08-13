import SwiftSoup
import Testing
import UIKit
@testable import yuedu_app

/// Phase 3A — link / annotation interaction.
///
/// The contract under test: a link exists because the DOM says so, its hit
/// region is the geometry the layout already produced, and every href kind
/// (same-spine, cross-spine, noteref, backlink, external) resolves through one
/// resolver. Nothing here may move a fragment.
@MainActor
struct BrowserLayoutLinkInteractionTests {

    // MARK: - Helpers

    private static let iconImage = BrowserLayoutTestSupport.makeImage(
        size: CGSize(width: 20, height: 20), color: .red
    )

    private static func layout(
        _ html: String,
        width: CGFloat = 300,
        height: CGFloat = 400
    ) async throws -> (pages: [PageFragments], doc: BrowserLayoutDocument) {
        try await BrowserLayoutTestSupport.layout(
            html, width: width, height: height,
            imageLoader: { _ in iconImage }
        )
    }

    /// Regions for one page, built exactly the way the engine builds them.
    private static func regions(
        page: PageFragments,
        doc: BrowserLayoutDocument,
        spineIndex: Int = 0
    ) -> LinkInteractionRegionSet {
        let list = DisplayListBuilder.build(for: page, sourceText: doc.lastSourceText)
        return LinkInteractionRegionSet.build(
            from: list, spineIndex: spineIndex, anchors: doc.lastLinkAnchors
        )
    }

    private static func allRegions(
        _ pages: [PageFragments],
        doc: BrowserLayoutDocument
    ) -> [LinkInteractionRegion] {
        pages.flatMap { regions(page: $0, doc: doc).regions }
    }

    private static func center(of region: LinkInteractionRegion) -> CGPoint {
        CGPoint(x: region.pageLocalRect.midX, y: region.pageLocalRect.midY)
    }

    // MARK: - 1. Same-spine text anchor

    @Test func sameSpineTextAnchorProducesRegionAndTarget() async throws {
        let html = """
        <html><body>
        <p id="target">Target paragraph.</p>
        <p><a href="#target">Jump to target</a></p>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        let links = Self.allRegions(pages, doc: doc)

        #expect(!links.isEmpty, "a plain <a href> produced no interaction region")
        #expect(links.allSatisfy { $0.href == "#target" })
        #expect(links.allSatisfy { $0.semantic == .plain })
        #expect(links.allSatisfy { $0.kind == .text })
        #expect(links.allSatisfy { $0.spineIndex == 0 })

        // The target id resolves to a source offset (the shared mapping that
        // TOC / search / restore also read).
        let offset = try #require(doc.lastAnchorOffsets["target"])
        #expect(offset >= 0)

        let resolver = LinkResolver(chapterHrefs: ["chapter0.xhtml"])
        #expect(resolver.resolve(href: "#target", fromSpine: 0)
                == .internalTarget(spineIndex: 0, fragment: "target"))
    }

    /// `<a name="x">` / `<a>` without an href is not a link and must not become
    /// a tap target — otherwise plain prose grows invisible dead zones.
    @Test func anchorWithoutHrefIsNotALink() async throws {
        let html = "<html><body><p><a name=\"x\">Not a link</a> ordinary text.</p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        #expect(Self.allRegions(pages, doc: doc).isEmpty)
    }

    // MARK: - 2. Cross-spine anchor

    @Test func crossSpineHrefResolvesToTargetSpineAndFragment() {
        let resolver = LinkResolver(chapterHrefs: [
            "Text/chapter1.xhtml",
            "Text/chapter2.xhtml",
            "Text/notes.xhtml",
        ])
        #expect(resolver.resolve(href: "chapter2.xhtml#target", fromSpine: 0)
                == .internalTarget(spineIndex: 1, fragment: "target"))
        // The form the spec calls out: a sibling directory hop.
        #expect(resolver.resolve(href: "../Text/notes.xhtml#note1", fromSpine: 0)
                == .internalTarget(spineIndex: 2, fragment: "note1"))
        // No fragment → the chapter itself. The href is relative to the LINKING
        // chapter's directory, so a sibling in `Text/` is authored bare.
        #expect(resolver.resolve(href: "notes.xhtml", fromSpine: 1)
                == .internalTarget(spineIndex: 2, fragment: nil))
        // Root-relative form of the same target.
        #expect(resolver.resolve(href: "/Text/notes.xhtml", fromSpine: 1)
                == .internalTarget(spineIndex: 2, fragment: nil))
        // A path that matches no spine item is NOT silently rewritten into the
        // current chapter (that jumped the reader to the top of whatever it was
        // showing).
        #expect(resolver.resolve(href: "missing.xhtml#x", fromSpine: 0)
                == .unresolvable("missing.xhtml#x"))
    }

    @Test func externalURLsAreExternalAndOtherSchemesAreNot() {
        let resolver = LinkResolver(chapterHrefs: ["chapter0.xhtml"])
        #expect(resolver.resolve(href: "https://example.com/a", fromSpine: 0)
                == .external(URL(string: "https://example.com/a")!))
        #expect(resolver.resolve(href: "http://example.com/a", fromSpine: 0)
                == .external(URL(string: "http://example.com/a")!))
        // A book must not be able to make the reader open arbitrary schemes.
        #expect(resolver.resolve(href: "mailto:a@b.c", fromSpine: 0)
                == .unresolvable("mailto:a@b.c"))
    }

    @Test func crossSpineLinkRegionCarriesTheAuthoredHref() async throws {
        let html = "<html><body><p><a href=\"chapter2.xhtml#target\">Next chapter note</a></p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        let links = Self.allRegions(pages, doc: doc)
        #expect(!links.isEmpty)
        #expect(links.allSatisfy { $0.href == "chapter2.xhtml#target" })
    }

    // MARK: - 3. Image links

    @Test func inlineImageInsideAnchorIsTappable() async throws {
        let html = "<html><body><p>Before<a href=\"#note\"><img src=\"icon.png\"/></a>After</p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        let links = Self.allRegions(pages, doc: doc)

        let imageLink = try #require(
            links.first { $0.kind == .image },
            "an <img> wrapped in <a href> produced no link region — the annotation icon renders but cannot be tapped"
        )
        #expect(imageLink.href == "#note")
    }

    /// The `display: block` image path has no line run at all: the attachment on
    /// the block box is the only carrier of DOM identity, and it used to be
    /// built with `nodeID: -1, linkTarget: nil`.
    @Test func blockLevelImageInsideAnchorIsTappable() async throws {
        let html = """
        <html><body>
        <a href="#note" style="display:block"><img src="icon.png" style="display:block"/></a>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        let links = Self.allRegions(pages, doc: doc)
        let imageLink = try #require(
            links.first { $0.kind == .image },
            "a block-level <img> inside <a href> lost its link on the way to the page"
        )
        #expect(imageLink.href == "#note")
    }

    @Test func imageLinkHitRectEqualsTheImageFragmentRect() async throws {
        let html = "<html><body><p><a href=\"#note\"><img src=\"icon.png\"/></a></p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        let fragment = try #require(
            BrowserLayoutTestSupport.allImageFragments(pages).first { $0.linkTarget != nil }
        )
        let region = try #require(Self.allRegions(pages, doc: doc).first { $0.kind == .image })
        #expect(region.pageLocalRect == fragment.rect.rawValue,
                "region \(region.pageLocalRect) != image fragment \(fragment.rect.rawValue)")
    }

    /// A CSS background is paint, not an element: it covers the whole canvas and
    /// must never become a link (or a tap anywhere would follow one).
    @Test func cssBackgroundPaintIsNeverALink() async throws {
        let html = """
        <html><body style="background-image:url(bg.png)">
        <p><a href="#target">Only this is a link</a></p>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        let links = Self.allRegions(pages, doc: doc)
        #expect(links.allSatisfy { $0.kind == .text })
        let page = try #require(pages.first)
        let set = Self.regions(page: page, doc: doc)
        // A corner well away from the paragraph: covered by the background
        // paint, but not by any link.
        #expect(set.hitTest(CGPoint(x: page.pageRect.width - 4, y: page.pageRect.height - 4)) == nil)
    }

    // MARK: - 4. noteref → popup

    @Test func noterefAnchorCarriesTheEPUBSemantic() async throws {
        let html = """
        <html><body>
        <p>Body text<a epub:type="noteref" href="#n1">1</a>.</p>
        <aside epub:type="footnote" id="n1"><p>The note body.</p></aside>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        let noteref = try #require(
            Self.allRegions(pages, doc: doc).first { $0.href == "#n1" },
            "no region for the noteref marker"
        )
        #expect(noteref.semantic == .noteref,
                "epub:type=\"noteref\" did not reach the interaction region")
    }

    @Test func doubleNoterefRoleIsRecognized() async throws {
        let html = """
        <html><body>
        <p>Body text<a role="doc-noteref" href="#n1">1</a>.</p>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        let noteref = try #require(Self.allRegions(pages, doc: doc).first { $0.href == "#n1" })
        #expect(noteref.semantic == .noteref)
    }

    /// The note BODY is what the popup shows. EPUB 3 marks it with `epub:type`
    /// on any element — the 多看 `<li class="…footnote…">` idiom is only one
    /// spelling of the same thing.
    @Test func footnoteBodiesAreCollectedFromEPUBSemanticsAndFromDuokanClasses() throws {
        let html = """
        <html><body>
        <aside epub:type="footnote" id="n1"><p>Semantic note body.</p></aside>
        <ol class="duokan-footnote-content">
          <li class="duokan-footnote-item" id="m1">Duokan note body.</li>
        </ol>
        </body></html>
        """
        let document = try SwiftSoup.parse(html)
        let notes = BrowserLayoutDocument.collectFootnotes(in: document)
        #expect(notes["n1"]?.contains("Semantic note body") == true)
        #expect(notes["m1"]?.contains("Duokan note body") == true)
    }

    /// A note tap must hand the note text back to the PRESENTER (the page view
    /// controller, which anchors a popover at the marker) and must not navigate.
    ///
    /// This is the contract that broke when the browser engine was switched on:
    /// notes were routed to a reader-level `(String) -> Void` callback that had
    /// no anchor, so every note came up as a bottom sheet.
    @Test func footnoteTapIsPresentedAtTheMarkerAndDoesNotNavigate() async throws {
        // A spine index of its own: FootnoteStore is process-global and these
        // suites run in parallel.
        let spine = 7701
        FootnoteStore.index(notes: ["n1": "The note body."], spineIndex: spine)
        defer { FootnoteStore.index(notes: [:], spineIndex: spine) }

        let resource = MockBrowserLayoutResource(chapters: [
            MockBrowserLayoutResource.Chapter(
                title: "c", href: "c0.xhtml",
                html: "<html><body><p>Body<a href=\"#n1\">1</a>.</p></body></html>", css: []
            )
        ])
        let builder = MockAttributedStringBuilder(texts: ["c"])
        let store = CharOffsetStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("fn-\(UUID().uuidString)")
        )
        let settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let delegate = CoreTextPageEngine(
            attributedBuilder: builder, renderSettings: settings, offsetStore: store
        )
        let engine = BrowserLayoutPageEngine(
            resource: resource, delegate: delegate, settings: settings, mode: .browserAuto
        )

        var navigated: [Int] = []
        engine.onLinkNavigate = { navigated.append($0) }
        var presented: [String] = []

        let marker = LinkInteractionRegion(
            pageLocalRect: CGRect(x: 40, y: 80, width: 12, height: 16),
            href: "#n1", linkID: 3, nodeID: 3,
            sourceRange: NSRange(location: 4, length: 1),
            spineIndex: spine, semantic: .noteref, kind: .text
        )
        engine.activateLink(marker) { presented.append($0) }

        #expect(presented == ["The note body."],
                "the note text must reach the presenter, got \(presented)")
        #expect(navigated.isEmpty, "a note tap must not page the reader anywhere")
    }

    // MARK: - 5. Backlink

    /// The 多看 reference marker is `<a id="ref" href="#note"><img/></a>` — an
    /// element whose only content is an image. Registering anchor offsets at
    /// text alone lost that id, so the note's "返回正文" link resolved to a
    /// missing anchor and landed at the top of the chapter.
    @Test func backlinkTargetOnAnImageOnlyAnchorIsAddressable() async throws {
        let html = """
        <html><body>
        <p>Sentence one. Sentence two.<a id="ref1" href="#n1"><img src="icon.png"/></a> Sentence three.</p>
        <ol class="duokan-footnote-content">
          <li class="duokan-footnote-item" id="n1">Note body. <a href="#ref1">Back to text</a></li>
        </ol>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)

        let backOffset = try #require(
            doc.lastAnchorOffsets["ref1"],
            "the image-only reference marker never registered its id — 返回正文 cannot land on it"
        )
        #expect(backOffset > 0, "the marker sits mid-paragraph, not at the chapter start")

        let backlink = try #require(
            Self.allRegions(pages, doc: doc).first { $0.href == "#ref1" },
            "no region for the backlink"
        )
        // A backlink is an ordinary link — no separate return-coordinate state.
        #expect(backlink.semantic == .plain)
        let resolver = LinkResolver(chapterHrefs: ["chapter0.xhtml"])
        #expect(resolver.resolve(href: backlink.href, fromSpine: 0)
                == .internalTarget(spineIndex: 0, fragment: "ref1"))
    }

    // MARK: - 6/7. One link, many fragments

    @Test func linkSpanningSeveralRunsSharesOneIdentity() async throws {
        let html = "<html><body><p><a href=\"#t\"><b>Bold part</b> and plain part</a></p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        let links = Self.allRegions(pages, doc: doc)
        #expect(links.count >= 2, "expected one region per run, got \(links.count)")
        #expect(Set(links.map(\.href)) == ["#t"])
        #expect(Set(links.map(\.linkID)).count == 1,
                "runs of the same <a> reported different link identities")
    }

    @Test func linkSpanningTwoLinesProducesTwoRegionsWithOneIdentity() async throws {
        let html = """
        <html><body><p><a href="#t">\
        A deliberately long link label that cannot possibly fit on a single line here\
        </a></p></body></html>
        """
        let (pages, doc) = try await Self.layout(html, width: 200)
        let links = Self.allRegions(pages, doc: doc)
        #expect(Set(links.map(\.linkID)).count == 1)
        let distinctRows = Set(links.map { $0.pageLocalRect.minY.rounded() })
        #expect(distinctRows.count >= 2,
                "expected the link to wrap onto at least two lines, rows=\(distinctRows.sorted())")
        // Every piece is tappable, not just the first line.
        let set = Self.regions(page: try #require(pages.first), doc: doc)
        for region in set.regions {
            #expect(set.hitTest(Self.center(of: region))?.linkID == region.linkID)
        }
    }

    // MARK: - 9. Blank space around a link

    @Test func tappingBesideALinkDoesNotFollowIt() async throws {
        let html = """
        <html><body>
        <p><a href="#target">Short link</a></p>
        <p>Plain paragraph that is not a link at all and sits below it.</p>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        let page = try #require(pages.first)
        let set = Self.regions(page: page, doc: doc)
        let link = try #require(set.regions.first)

        #expect(set.hitTest(Self.center(of: link))?.href == "#target")
        // Far to the right of the label, on the same line.
        #expect(set.hitTest(CGPoint(x: link.pageLocalRect.maxX + 60, y: link.pageLocalRect.midY)) == nil)
        // Well below it, inside the plain paragraph.
        #expect(set.hitTest(CGPoint(x: link.pageLocalRect.midX, y: link.pageLocalRect.maxY + 60)) == nil)
    }

    // MARK: - 6 (feedback). Press lifecycle

    private func makePressView(
        _ set: LinkInteractionRegionSet
    ) -> (view: BrowserLayoutPageView, region: LinkInteractionRegion) {
        let view = BrowserLayoutPageView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        view.interactionRegions = set
        return (view, set.regions[0])
    }

    @Test func touchDownOnALinkEntersPressedState() async throws {
        let html = "<html><body><p><a href=\"#target\">Press me</a></p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        let set = Self.regions(page: try #require(pages.first), doc: doc)
        let (view, region) = makePressView(set)

        #expect(view.linkInteractionState == .normal)
        view.beginLinkPress(at: Self.center(of: region))
        #expect(view.linkInteractionState == .pressed)
        #expect(view.pressedLinkRegion?.linkID == region.linkID)
    }

    @Test func draggingOffTheLinkCancelsWithoutActivating() async throws {
        let html = "<html><body><p><a href=\"#target\">Press me</a></p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        let set = Self.regions(page: try #require(pages.first), doc: doc)
        let (view, region) = makePressView(set)

        var activated: [LinkInteractionRegion] = []
        view.onLinkActivate = { activated.append($0) }

        let inside = Self.center(of: region)
        view.beginLinkPress(at: inside)
        view.updateLinkPress(at: CGPoint(x: inside.x, y: inside.y + 120))
        #expect(view.linkInteractionState == .normal)
        #expect(view.pressedLinkRegion == nil)

        // Coming back and lifting must NOT activate: this touch was cancelled.
        #expect(view.endLinkPress(at: inside) == nil)
        #expect(activated.isEmpty)
    }

    @Test func liftingInsideTheLinkActivatesItOnce() async throws {
        let html = "<html><body><p><a href=\"#target\">Press me</a></p></body></html>"
        let (pages, doc) = try await Self.layout(html)
        let set = Self.regions(page: try #require(pages.first), doc: doc)
        let (view, region) = makePressView(set)

        var activated: [LinkInteractionRegion] = []
        var stateWhileActivating: BrowserLayoutPageView.LinkInteractionState?
        view.onLinkActivate = { region in
            stateWhileActivating = view.linkInteractionState
            activated.append(region)
        }

        let inside = Self.center(of: region)
        view.beginLinkPress(at: inside)
        #expect(view.endLinkPress(at: inside)?.href == "#target")
        #expect(activated.count == 1)
        #expect(stateWhileActivating == .activated)
        // The state is momentary; the press is released afterwards.
        #expect(view.linkInteractionState == .normal)
        #expect(view.pressedLinkRegion == nil)

        // A second lift with no new press does nothing.
        #expect(view.endLinkPress(at: inside) == nil)
        #expect(activated.count == 1)
    }

    @Test func pressWithoutALinkNeverArmsActivation() async throws {
        let html = """
        <html><body>
        <p><a href="#target">Link</a></p>
        <p>Plain paragraph well below the link.</p>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)
        let set = Self.regions(page: try #require(pages.first), doc: doc)
        let (view, region) = makePressView(set)

        var activated: [LinkInteractionRegion] = []
        view.onLinkActivate = { activated.append($0) }

        let blank = CGPoint(x: region.pageLocalRect.midX, y: region.pageLocalRect.maxY + 80)
        #expect(view.beginLinkPress(at: blank) == nil)
        #expect(view.linkInteractionState == .normal)
        #expect(view.endLinkPress(at: blank) == nil)
        #expect(activated.isEmpty)
    }

    // MARK: - 11. Regions consume geometry, never change it

    @Test func buildingRegionsDoesNotDisturbPagination() async throws {
        let html = """
        <html><body>
        <p><a href="#a">Link one</a> and some following prose to fill the line.</p>
        <p><a href="#b"><img src="icon.png"/></a> plus a paragraph after the icon.</p>
        <p>\(String(repeating: "Filler sentence to force more than one page. ", count: 40))</p>
        </body></html>
        """
        let (pages, doc) = try await Self.layout(html)

        func digest(_ pages: [PageFragments]) -> [String] {
            pages.flatMap { page -> [String] in
                var out: [String] = ["page \(page.index) \(page.pageRect.rawValue)"]
                for fragment in BrowserLayoutTestSupport.allTextFragments([page]) {
                    out.append("t \(fragment.rect.rawValue)")
                }
                for fragment in BrowserLayoutTestSupport.allImageFragments([page]) {
                    out.append("i \(fragment.rect.rawValue)")
                }
                return out
            }
        }

        let before = digest(pages)
        let built = Self.allRegions(pages, doc: doc)
        #expect(!built.isEmpty, "the fixture should contain links")
        #expect(digest(pages) == before, "building interaction regions changed page geometry")

        // Every region's rect IS a fragment rect — regions never synthesize a
        // position of their own.
        var fragmentRects = Set<String>()
        for fragment in BrowserLayoutTestSupport.allTextFragments(pages) {
            fragmentRects.insert("\(fragment.rect.rawValue)")
        }
        for fragment in BrowserLayoutTestSupport.allImageFragments(pages) {
            fragmentRects.insert("\(fragment.rect.rawValue)")
        }
        for region in built {
            #expect(fragmentRects.contains("\(region.pageLocalRect)"),
                    "region rect \(region.pageLocalRect) matches no fragment")
        }
    }
}
