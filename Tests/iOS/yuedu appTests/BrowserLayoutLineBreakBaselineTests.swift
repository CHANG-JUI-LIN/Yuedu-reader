import CryptoKit
import Testing
import UIKit
@testable import yuedu_app

/// LINE-BREAK REGRESSION NET for the whole book.
///
/// Phase 3 (CSS Float) moves line layout out of `BoxTreeBuilder` (where it runs
/// today, at box-tree build time) and into `BlockLayout`, because a float's
/// exclusion region is a function of the block position `y` — which does not
/// exist yet when the lines are currently shaped. That reorder touches EVERY
/// chapter, not just the 5 that actually float, so it needs a net first.
///
/// The net is a per-chapter fingerprint of every laid-out line: its rect and a
/// hash of its text. Book text is NEVER written to disk — only geometry and
/// digests — so the golden is committable and small (one line per chapter).
///
/// Regenerate deliberately with `YUEDU_LINEBREAK_REGEN=1`; a run with no golden
/// present writes one and reports that it did, rather than passing silently.
@MainActor
struct BrowserLayoutLineBreakBaselineTests {

    static let viewport = CGSize(width: 390, height: 844)
    static let settings = ReaderRenderSettings(
        theme: "paper", textColor: .black, backgroundColor: .white,
        fontSize: 17, lineHeightMultiple: 1.4, lineSpacing: 0, paragraphSpacing: 6,
        letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
        contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    )
    static var contentSize: CGSize {
        CGSize(width: viewport.width - settings.contentInsets.left - settings.contentInsets.right,
               height: viewport.height - settings.contentInsets.top - settings.contentInsets.bottom)
    }

    nonisolated static var epubPath: String? {
        if let env = ProcessInfo.processInfo.environment["YUEDU_HONGLOUMENG_EPUB_PATH"], !env.isEmpty {
            return env
        }
        let local = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《红楼梦+大观红楼》人民文学出版.epub"
        return FileManager.default.fileExists(atPath: local) ? local : nil
    }

    /// Repo-relative golden, resolved from this source file's own location.
    nonisolated static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // yuedu appTests
            .deletingLastPathComponent()   // iOS
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/browser-layout/line-break-baseline/redchamber.tsv")
    }

    /// Chapters to cover. Default: the whole spine. `YUEDU_LINEBREAK_STRIDE=n`
    /// samples every n-th chapter for a fast local loop.
    nonisolated static var stride: Int {
        Int(ProcessInfo.processInfo.environment["YUEDU_LINEBREAK_STRIDE"] ?? "") ?? 1
    }

    // MARK: - Fingerprint

    /// `spine <TAB> pages <TAB> lines <TAB> firstRect <TAB> lastRect <TAB> sha`
    /// Text never appears — only its digest, folded into `sha`.
    struct ChapterPrint: Equatable {
        var spine: Int
        var pages: Int
        var lines: Int
        var first: String
        var last: String
        var sha: String

        var row: String { "\(spine)\t\(pages)\t\(lines)\t\(first)\t\(last)\t\(sha)" }

        static func parse(_ row: String) -> ChapterPrint? {
            let f = row.components(separatedBy: "\t")
            guard f.count == 6, let spine = Int(f[0]), let pages = Int(f[1]), let lines = Int(f[2]) else {
                return nil
            }
            return ChapterPrint(spine: spine, pages: pages, lines: lines,
                                first: f[3], last: f[4], sha: f[5])
        }
    }

    static func rect(_ r: CGRect) -> String {
        String(format: "%.2f,%.2f,%.2f,%.2f", r.minX, r.minY, r.width, r.height)
    }

    static func fingerprint(spine: Int, pages: [PageFragments], sourceText: String) -> ChapterPrint {
        var details: [String] = []
        for page in pages {
            for fragment in BrowserLayoutTestSupport.allTextFragments([page]) {
                let ns = sourceText as NSString
                let text: String
                if fragment.sourceRange.location >= 0,
                   fragment.sourceRange.location + fragment.sourceRange.length <= ns.length,
                   fragment.sourceRange.length > 0 {
                    text = ns.substring(with: fragment.sourceRange)
                } else {
                    text = ""
                }
                var hasher = SHA256()
                hasher.update(data: Data(text.utf8))
                let textDigest = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined().prefix(8)
                details.append("\(rect(fragment.rect.rawValue))|\(String(format: "%.2f", fragment.baselineY))|\(textDigest)")
            }
        }
        var all = SHA256()
        all.update(data: Data(details.joined(separator: "\n").utf8))
        let sha = all.finalize().compactMap { String(format: "%02x", $0) }.joined()
        return ChapterPrint(
            spine: spine, pages: pages.count, lines: details.count,
            first: details.first ?? "-", last: details.last ?? "-", sha: String(sha.prefix(16))
        )
    }

    // MARK: - Layout one chapter exactly as the batch path does

    static func layout(session: PublicationSession, spine: Int) async -> (pages: [PageFragments], sourceText: String)? {
        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        guard let html = try? await adapter.chapterHTML(at: spine), !html.isEmpty else { return nil }
        let css = await adapter.processedCSS(forChapter: spine)
        let scan = BrowserLayoutCapabilityScanner.scan(html: html, cssTexts: css)
        guard scan.supported else { return nil }
        let images = await adapter.prefetchImages(
            forChapter: spine, html: html, renderWidth: contentSize.width
        )
        let config = BrowserLayoutConfig(
            renderWidth: contentSize.width, renderHeight: contentSize.height,
            rootFontSize: settings.fontSize, fontFamilies: [],
            textColor: settings.textColor, backgroundColor: settings.backgroundColor,
            contentInsets: settings.contentInsets, lineHeight: settings.lineHeightMultiple,
            fontResolver: adapter.fontResolver()
        )
        let doc = BrowserLayoutDocument(html: html, cssTexts: css, config: config, imageLoader: { images[$0] })
        guard let pages = try? await doc.renderPages(containerSize: viewport) else { return nil }
        return (pages, doc.lastSourceText)
    }

    // MARK: - The net

    @Test("line breaking is byte-identical across the whole book", .enabled(if: epubPath != nil))
    func lineBreakingMatchesGolden() async throws {
        let path = try #require(Self.epubPath)
        let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: path))

        var prints: [ChapterPrint] = []
        var skipped: [Int] = []
        let started = Date()
        for spine in Swift.stride(from: 0, to: session.chapters.count, by: Self.stride) {
            guard let (pages, sourceText) = await Self.layout(session: session, spine: spine) else {
                skipped.append(spine)
                continue
            }
            prints.append(Self.fingerprint(spine: spine, pages: pages, sourceText: sourceText))
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        print("LINEBREAK covered=\(prints.count) skipped(unsupported)=\(skipped.count) stride=\(Self.stride) in \(elapsed)s")

        let regen = ProcessInfo.processInfo.environment["YUEDU_LINEBREAK_REGEN"] == "1"
        let url = Self.goldenURL
        let existing = try? String(contentsOf: url, encoding: .utf8)

        if regen || existing == nil {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let body = ([
                "# line-break baseline — geometry + text DIGESTS only, no book text",
                "# spine\tpages\tlines\tfirstLine\tlastLine\tsha",
            ] + prints.map(\.row)).joined(separator: "\n") + "\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
            // A missing golden must NOT pass silently — the net only has value
            // once it exists and a later run compares against it.
            #expect(regen, "no golden existed; wrote \(prints.count) chapters to \(url.path). Re-run to compare.")
            return
        }

        let goldenRows = existing!
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { ChapterPrint.parse(String($0)) }
        #expect(!goldenRows.isEmpty, "golden is present but unparsable: \(url.path)")

        let goldenBySpine = Dictionary(uniqueKeysWithValues: goldenRows.map { ($0.spine, $0) })
        let mineBySpine = Dictionary(uniqueKeysWithValues: prints.map { ($0.spine, $0) })

        let onlyGolden = Set(goldenBySpine.keys).subtracting(mineBySpine.keys).sorted().prefix(10)
        let onlyNow = Set(mineBySpine.keys).subtracting(goldenBySpine.keys).sorted().prefix(10)
        let coverageNote = "chapter coverage changed: only-in-golden=\(Array(onlyGolden)) only-now=\(Array(onlyNow))"
        #expect(Set(goldenBySpine.keys) == Set(mineBySpine.keys), "\(coverageNote)")

        var changed: [String] = []
        for (spine, want) in goldenBySpine.sorted(by: { $0.key < $1.key }) {
            guard let got = mineBySpine[spine] else { continue }
            guard got != want else { continue }
            changed.append(
                "spine \(spine): pages \(want.pages)→\(got.pages) lines \(want.lines)→\(got.lines)\n"
                + "    first  want=\(want.first)\n           got =\(got.first)\n"
                + "    last   want=\(want.last)\n           got =\(got.last)"
            )
        }
        let changedNote = "\(changed.count) chapters changed their line breaking:\n"
            + changed.prefix(8).joined(separator: "\n")
        #expect(changed.isEmpty, "\(changedNote)")
    }
}
