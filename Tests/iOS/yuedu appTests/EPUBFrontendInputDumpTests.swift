import Foundation
import Testing
import YueduCoreText
@testable import yuedu_app

/// Opt-in: dumps the five loading-benchmark chapters' frontend
/// inputs so the package can time its own stages on real chapters.
@MainActor
struct EPUBFrontendInputDumpTests {
    @Test func dumpBenchmarkChapterInputs() async throws {
        guard let dir = ProcessInfo.processInfo.environment["YUEDU_FRONTEND_DUMP_DIR"] else { return }
        let books: [(id: String, filename: String, spine: Int)] = [
            ("quanzhi-prose", "《全职高手3》作者：蝴蝶蓝.epub", 69),
            ("guimi-prose", "《诡秘之主4》作者：爱潜水的乌贼.epub", 80),
            ("hail-mary-prose", "Project Hail Mary (Andy Weir) (z-library.sk, 1lib.sk, z-lib.sk).epub", 6),
            ("game-designer-fallback", "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub", 10),
            ("guimi-long", "《诡秘之主4》作者：爱潜水的乌贼.epub", 64),
        ]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for book in books {
            let url = URL(fileURLWithPath: "/Users/zhangruilin/Desktop/Test document/EPUB Format")
                .appendingPathComponent(book.filename)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let session = try await PublicationSession.open(sourceURL: url)
            let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
            let html = try await session.chapterHTML(at: book.spine)
            let input = await adapter.cssFrontendInput(forChapter: book.spine, html: html)
            let sheets: [[String: Any]] = input.stylesheets.map { sheet in
                var source: [String: Any]
                switch sheet.source {
                case .inline(let ordinal): source = ["inline": ordinal]
                case .linked(let href): source = ["linked": href]
                }
                return [
                    "source": source, "text": sheet.text, "sourceOrder": sheet.sourceOrder,
                    "currentCompatibilityOrder": sheet.currentCompatibilityOrder as Any,
                    "currentCompatibilityOnly": sheet.currentCompatibilityOnly,
                    "media": sheet.media as Any, "isAlternate": sheet.isAlternate, "loadFailed": sheet.loadFailed,
                ]
            }
            let payload: [String: Any] = ["id": book.id, "spine": book.spine, "html": input.html, "stylesheets": sheets]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(book.id).json"))
            print("FRONTEND-DUMP \(book.id) html=\(input.html.utf8.count) sheets=\(input.stylesheets.count)")
        }
    }
}
