@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// A chapter with no text — a full-page map, a cover, a video page (剑来) — has no line
/// for its reading position to land on. The restore and the anchored viewport request
/// both waited for that line, so every layout that arrived asked for itself again and
/// re-applied the restore, about 4000 times a second: the reader shook in place and
/// could not be scrolled, opening at the cover or after switching from paged mode on
/// a map, and scrolling onto the video page.
@Suite(.serialized)
@MainActor
struct BrowserViewportTextlessChapterTests {
    private struct Mounted {
        let engine: CoreTextScrollEngine
        let controller: CoreTextCollectionScrollViewController
        let collection: UICollectionView
        let window: UIWindow
    }

    private static let prose = (0..<40).map {
        "<p>第\($0)段：" + String(repeating: "風穿過山林，江水映著月光。", count: 6) + "</p>"
    }.joined()
    /// 剑来's map pages: white space around one picture, so the source text is a lone space.
    private static let map = "\n  <img class='width100' src='../Images/DT1.jpg' width='1080' height='2400'/>\n"
    /// 剑来's video pages: a hidden heading and a video, no source text at all.
    private static let video = """
        <h2 style="display:none" title="知我"></h2><div style="margin:100% auto 0 auto">\
        <video poster="../Images/video01.jpg" style="width:100%"><source src="../Video/video.mp4" type="video/mp4"/></video>\
        </div>
        """

    /// A real EPUB, so the map and the poster are real pictures laid out by the browser engine.
    private func archive(_ bodies: [String]) async throws -> URL {
        let items = bodies.indices.map {
            "<item id='c\($0)' href='Text/\($0).xhtml' media-type='application/xhtml+xml'/>"
        }.joined()
        let spine = bodies.indices.map { "<itemref idref='c\($0)'/>" }.joined()
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8),
            "OPS/package.opf": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString)</dc:identifier>
                    <dc:title>Textless</dc:title><dc:language>zh</dc:language>
                  </metadata>
                  <manifest>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="map" href="Images/DT1.jpg" media-type="image/jpeg"/>
                    <item id="poster" href="Images/video01.jpg" media-type="image/jpeg"/>
                    \(items)
                  </manifest>
                  <spine>\(spine)</spine>
                </package>
                """.utf8),
            "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(title: "Nav",
                body: #"<nav epub:type="toc"><ol><li><a href="Text/0.xhtml">0</a></li></ol></nav>"#).utf8),
            "OPS/Images/DT1.jpg": EPUBTestFixtures.makeJPEG(width: 1080, height: 2400),
            "OPS/Images/video01.jpg": EPUBTestFixtures.makeJPEG(width: 1280, height: 720),
        ]
        for (index, body) in bodies.enumerated() {
            entries["OPS/Text/\(index).xhtml"] = Data(EPUBTestFixtures.xhtml(title: "\(index)", body: body).utf8)
        }
        return try await EPUBTestFixtures.makeArchive(entries: entries)
    }

    private func mount(_ bodies: [String], initialChapter: Int,
                       position: (Int, CoreTextScrollEngine) -> Int) async throws -> Mounted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let settings = EPUBTestFixtures.renderSettings()
        let size = scene.coordinateSpace.bounds.size
        let session = try await PublicationSession.open(sourceURL: try await archive(bodies))
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: size)
        let delegate = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let browser = BrowserLayoutPageEngine(resource: EPUBBrowserLayoutResourceAdapter(session: session),
            delegate: delegate, settings: settings, mode: .browserAuto)
        browser.usesViewportScrolling = true
        await browser.start(renderSize: size, bookId: "textless-\(UUID().uuidString)")
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        engine.browserAutoEngine = browser
        await engine.start(initialChapter: initialChapter, contentWidth: size.width - 24,
                           imageContentWidth: size.width - 24, viewportExtent: size.height)
        await engine.waitForViewportIdle()
        let controller = CoreTextCollectionScrollViewController(engine: engine, axis: .vertical,
            sideInsets: .init(left: 12, right: 12), verticalInset: 20, backgroundColor: .white)
        controller.setInitialPosition(chapter: initialChapter, charOffset: position(initialChapter, engine))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        return Mounted(engine: engine, controller: controller, collection: collection, window: window)
    }

    private func viewportWork(_ m: Mounted) -> Bool {
        m.engine.chapterRanges.keys.compactMap { m.engine.browserChapter(at: $0) }.contains(where: \.hasViewportWork)
    }

    /// Layout settles: no request stays in flight, and a further layout pass (what every
    /// scroll frame and every arriving snapshot runs) asks for nothing more. While the bug
    /// lived the work never ended, so this polls with a deadline instead of awaiting idle.
    private func expectSettles(_ m: Mounted, _ comment: Comment) async throws {
        let deadline = Date().addingTimeInterval(5)
        while viewportWork(m) {
            guard Date() < deadline else {
                Issue.record("layout never settled: \(comment)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        m.controller.view.setNeedsLayout()
        m.controller.view.layoutIfNeeded()
        m.collection.layoutIfNeeded()
        #expect(!viewportWork(m), "a layout pass asked for more layout: \(comment)")
    }

    private func describe(_ m: Mounted) -> String {
        let frames = (0..<m.engine.chunks.count).map {
            m.collection.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame ?? .zero
        }
        return "offset=\(m.collection.contentOffset.y) content=\(m.collection.contentSize.height) "
            + "rows=\(m.engine.chunks.map(\.chapterIndex)) frames=\(frames)"
    }

    @Test("a restore onto a text-less chapter settles", arguments: [
        (chapter: 0, atEnd: false), (chapter: 0, atEnd: true), (chapter: 1, atEnd: false),
    ])
    func restoreOntoTextlessChapterSettles(chapter: Int, atEnd: Bool) async throws {
        let m = try await mount([Self.map, Self.video, Self.prose], initialChapter: chapter) { spine, engine in
            // The chapter's end: the position paged mode handed over for a page with no
            // text before YueduCoreText 0.10.2, when switching from paged mode on a map.
            atEnd ? ((engine.browserChapter(at: spine)?.attributedString.length) ?? 0) : 0
        }
        defer { m.window.isHidden = true; m.window.rootViewController = nil }
        try await expectSettles(m, "chapter \(chapter) atEnd=\(atEnd)")
        let saved = m.controller.positionForPersistence()
        #expect(saved?.spineIndex == chapter, "saved \(String(describing: saved)) \(describe(m))")
    }

    /// With the video's middle at the viewport top, the topmost painted line is the next
    /// chapter's first: its anchor sits at offset 0, which the geometry commit used to
    /// resolve at the chapter's top edge instead of the line, 17pt (the paragraph's margin)
    /// higher — every layout that arrived pulled the reader back by that much.
    @Test("scrolling onto a video-only chapter settles and keeps scrolling")
    func scrollingOntoVideoChapterSettles() async throws {
        let m = try await mount([Self.prose, Self.video, Self.prose], initialChapter: 1) { _, _ in 0 }
        defer { m.window.isHidden = true; m.window.rootViewController = nil }
        try await expectSettles(m, "restore at the video chapter")
        // Put the video chapter's middle at the viewport top, as a reader scrolling through it does.
        let row = try #require(m.engine.chunkIndex(forChapter: 1, charOffset: 0))
        let frame = try #require(m.collection.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame)
        let target = CGPoint(x: 0, y: frame.midY - m.collection.adjustedContentInset.top)
        m.collection.setContentOffset(target, animated: false)
        m.controller.scrollViewDidScroll(m.collection)
        m.collection.layoutIfNeeded()
        try await expectSettles(m, "scrolled into the video chapter")
        #expect(abs(m.collection.contentOffset.y - target.y) < 1,
                "the reader stays where it was scrolled: target \(target.y) \(describe(m))")
    }
}
