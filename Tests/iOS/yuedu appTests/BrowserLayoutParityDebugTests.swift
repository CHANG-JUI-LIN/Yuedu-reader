import Testing
import UIKit
@testable import yuedu_app

/// Debug remaining parity failures: dump browser vs legacy text diffs for
/// chapters that differ after whitespace stripping.
@MainActor
struct BrowserLayoutParityDebugTests {

    @Test(.disabled("debug dump: writes /tmp artifacts for a human to read and asserts nothing. Enable manually when you need the dump; it must not run in the suite, where a bad fixture aborts the whole test process."))
    func debugRemainingParityFailures() async throws {
        let paths = [
            "/Users/zhangruilin/Desktop/Yuedu-browser-layout/docs/epub-regression/samples/paragraph-border-background.epub",
            "/Users/zhangruilin/Desktop/Yuedu-browser-layout/docs/epub-regression/samples/block-image-before-paragraph.epub",
            "/Users/zhangruilin/Desktop/Test document/EPUB Format/《全知读者视角01》sing N song(싱숑)著[Hooshaun制作].epub",
            "/Users/zhangruilin/Desktop/Test document/EPUB Format/《全职高手3》作者：蝴蝶蓝.epub",
        ]
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))
            let settings = ReaderRenderSettings(
                theme: "paper", textColor: .black, backgroundColor: .white,
                fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
                letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
                contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            )
            let renderSize = CGSize(width: 390, height: 800)
            for spine in 0..<min(8, session.chapters.count) {
                let html = try await session.chapterHTML(at: spine)
                let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
                let css = await adapter.processedCSS(forChapter: spine)
                let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
                if !scan.supported { continue }
                let images = await adapter.prefetchImages(forChapter: spine, html: html, renderWidth: renderSize.width - 24)
                let config = BrowserLayoutConfig(
                    renderWidth: renderSize.width - 24, renderHeight: renderSize.height - 24,
                    rootFontSize: 17, fontFamilies: [],
                    textColor: .black, backgroundColor: .white,
                    contentInsets: settings.contentInsets, lineHeight: 1.4,
                    fontResolver: adapter.fontResolver()
                )
                let document = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { images[$0] })
                let pages = try await document.renderPages(containerSize: renderSize)
                let browserText = BrowserLayoutTestSupport.visibleText(pages, sourceText: document.lastSourceText)
                let builder = EPUBAttributedStringBuilder(session: session, renderSize: renderSize)
                let result = try await builder.buildChapter(at: spine, settings: settings, themeTextColor: .black, themeBackgroundColor: .white)
                let legacyText = result.attributedString.string

                func strip(_ s: String) -> String {
                    s.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\u{FFFC}", with: "")
                }
                let a = strip(browserText)
                let b = strip(legacyText)
                guard a != b else { continue }
                let limit = min(a.count, b.count)
                var diff = -1
                for i in 0..<limit where Array(a)[i] != Array(b)[i] { diff = i; break }
                let name = (path as NSString).lastPathComponent
                try """
                \(name) spine=\(spine) browser=\(a.count) legacy=\(b.count) firstDiff=\(diff)
                browser@diff=\(String(a.dropFirst(max(0, diff - 30)).prefix(100)))
                legacy@diff=\(String(b.dropFirst(max(0, diff - 30)).prefix(100)))
                browserTail=\(String(a.suffix(80)))
                legacyTail=\(String(b.suffix(80)))
                """.write(toFile: "/tmp/parity-remaining.txt", atomically: true, encoding: .utf8)
            }
        }
        #expect(true)
    }
}
