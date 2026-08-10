import Testing
import UIKit
@testable import yuedu_app

/// Root-cause the single page-count difference in 全知读者视角01:
/// per-page text assignment comparison between the legacy and browser engines,
/// with the first divergence point.
@MainActor
struct BrowserLayoutPageDiffDiagnosticsTests {

    @Test(.disabled("debug dump: writes /tmp artifacts for a human to read and asserts nothing. Enable manually when you need the dump; it must not run in the suite, where a bad fixture aborts the whole test process."))
    func diagnoseQuanzhiPageCountDiff() async throws {
        let path = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《全知读者视角01》sing N song(싱숑)著[Hooshaun制作].epub"
        guard FileManager.default.fileExists(atPath: path) else {
            print("DIFF: book missing")
            return
        }
        let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))
        let settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white,
            fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
            letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
        let renderSize = CGSize(width: 390, height: 800)

        var outputs: [String] = []
        for spine in 0..<min(12, session.chapters.count) {
            let html = try await session.chapterHTML(at: spine)
            let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
            let css = await adapter.processedCSS(forChapter: spine)
            let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
            if !scan.supported { continue }

            // Browser pages.
            let images = await adapter.prefetchImages(forChapter: spine, html: html, renderWidth: renderSize.width - 24)
            let config = BrowserLayoutConfig(
                renderWidth: renderSize.width - 24, renderHeight: renderSize.height - 24,
                rootFontSize: 17, fontFamilies: [],
                textColor: .black, backgroundColor: .white,
                contentInsets: settings.contentInsets, lineHeight: 1.4,
                fontResolver: adapter.fontResolver()
            )
            let document = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { images[$0] })
            let browserPages = try await document.renderPages(containerSize: renderSize)

            // Divergent chapter diagnostics: what does the browser actually see?
            if browserPages.map({ BrowserLayoutTestSupport.visibleText([$0], sourceText: document.lastSourceText) }).joined().isEmpty {
                outputs.append("== spine \(spine) browser text EMPTY — html head:")
                outputs.append("  \(String(html.prefix(600)))")
                outputs.append("  sourceText(\(document.lastSourceText.count)): \(document.lastSourceText.prefix(200))")
                outputs.append("  fragment kinds per page: \(browserPages.map { page in page.fragments.map { frag in { if case .text = frag { return "t" }; if case .fill = frag { return "f" }; if case .image = frag { return "i" }; return "g" }() }.joined() })")
                outputs.append("  anchors: \(document.lastAnchorOffsets)")
            }

            // Legacy pages.
            let builder = EPUBAttributedStringBuilder(session: session, renderSize: renderSize)
            let legacyResult = try await builder.buildChapter(at: spine, settings: settings, themeTextColor: .black, themeBackgroundColor: .white)
            let paginator = CoreTextPaginator()
            let legacyLayout = await paginator.paginate(
                spineIndex: spine, attrStr: legacyResult.attributedString,
                renderSize: renderSize, fontSize: settings.fontSize,
                lineSpacing: settings.lineSpacing, paragraphSpacing: settings.paragraphSpacing,
                letterSpacing: settings.letterSpacing, contentInsets: settings.contentInsets
            )
            let legacyText = legacyResult.attributedString.string as NSString

            func strip(_ s: String) -> String {
                s.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
            }

            // Per-page normalized text for both engines.
            let browserPageTexts = browserPages.map { page in
                strip(BrowserLayoutTestSupport.visibleText([page], sourceText: document.lastSourceText))
            }
            let legacyPageTexts = legacyLayout.pageRanges.map { range in
                strip(legacyText.substring(with: NSRange(location: range.location, length: range.length)))
            }

            let browserCount = browserPageTexts.count
            let legacyCount = legacyPageTexts.count
            let diff = abs(browserCount - legacyCount)
            if diff > max(1, legacyCount / 4) {
                outputs.append("== spine \(spine): browser \(browserCount) pages vs legacy \(legacyCount) pages")
                outputs.append("  html length: \(html.count), css count: \(css.count)")
                for (page, pageFragments) in browserPages.enumerated() {
                    let kinds = pageFragments.fragments.map { frag -> String in
                        if case .text = frag { return "t" }
                        if case .fill = frag { return "f" }
                        if case .image = frag { return "i" }
                        return "g"
                    }.joined()
                    outputs.append("  browser page \(page): \(kinds) text=\"\(browserPageTexts[safe: page].map { String($0.prefix(80)) } ?? "")\"")
                }
                for (page, range) in legacyLayout.pageRanges.enumerated() {
                    outputs.append("  legacy page \(page): range=\(range) text=\"\(legacyPageTexts[safe: page].map { String($0.prefix(80)) } ?? "")\"")
                }
            }

            outputs.append("== spine \(spine): browser \(browserCount) pages vs legacy \(legacyCount) pages")
            // Find the first page whose text assignment differs.
            let maxPages = max(browserCount, legacyCount)
            for page in 0..<maxPages {
                let b = page < browserCount ? browserPageTexts[page] : "<none>"
                let l = page < legacyCount ? legacyPageTexts[page] : "<none>"
                if b != l {
                    outputs.append("  first divergence at page \(page):")
                    outputs.append("    browser: \(String(b.prefix(120)))")
                    outputs.append("    legacy:  \(String(l.prefix(120)))")
                    break
                }
            }
            // Where does the page count diverge (page index from which counts differ)?
            var sameUntil = 0
            for page in 0..<min(browserCount, legacyCount) where browserPageTexts[page] == legacyPageTexts[page] {
                sameUntil = page + 1
            }
            outputs.append("  identical pages: 0..\(sameUntil)")
            if sameUntil < legacyCount {
                outputs.append("  browser pages after \(sameUntil): \(browserPageTexts[safe: sameUntil].map { String($0.prefix(60)) } ?? "<none>")")
                outputs.append("  legacy pages after \(sameUntil):  \(legacyPageTexts[safe: sameUntil].map { String($0.prefix(60)) } ?? "<none>")")
            }
        }
        let report = outputs.joined(separator: "\n")
        try report.write(toFile: "/tmp/page-diff-report.txt", atomically: true, encoding: .utf8)
        print("DIFF-REPORT\n\(report)")
        #expect(true)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
