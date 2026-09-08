import Testing
import UIKit
@testable import yuedu_app

/// Local, opt-in corpus acceptance. The portable regressions live in
/// EPUBRenderingTests and BrowserLayoutPageEngineTests; books are not vendored.
@Suite(.serialized)
@MainActor
struct ReaderInteractionCorpusTests {
    private static let corpus = "/Users/zhangruilin/Desktop/Test document/EPUB Format/"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: corpus + "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub")))
    func gameDesignerBackgroundChaptersKeepTheirOwnPosition() async throws {
        let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath:
            Self.corpus + "《全能游戏设计师1》作者：冷陌 & 青衫取醉.epub"))
        let settings = EPUBTestFixtures.renderSettings()
        let size = CGSize(width: 440, height: 900)
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: size)
        let engine = CoreTextPageEngine(attributedBuilder: builder, renderSettings: settings,
            offsetStore: CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await engine.start(renderSize: size, bookId: UUID().uuidString)
        for spine in [3, 4] {
            let built = try await builder.buildChapter(at: spine, settings: settings,
                themeTextColor: .black, themeBackgroundColor: .white)
            #expect(built.pageBackgroundImage != nil)
            let outcome = await engine.preloadChapter(at: spine)
            #expect(outcome != .contentUnavailable)
            let layout = try #require(engine.layouts[spine])
            #expect(layout.pageRanges.count == 1)
            #expect(layout.pageBackgroundImage != nil)
            let page = try #require(engine.pageIndex(for: .chapterStart(spine)))
            #expect(engine.readingPosition(forPage: page)?.spineIndex == spine)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: corpus + "壹▪洪武大帝.epub")))
    func hongwuTimelineFootnoteUsesItsEmbeddedHotspot() async throws {
        let session = try await PublicationSession.open(sourceURL: URL(fileURLWithPath: Self.corpus + "壹▪洪武大帝.epub"))
        let settings = EPUBTestFixtures.renderSettings()
        let size = CGSize(width: 440, height: 900)
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: size)
        let built = try await builder.buildChapter(at: 2, settings: settings, themeTextColor: .black, themeBackgroundColor: .white)
        let note = try #require(FootnoteStore.text(spineIndex: 2, href: "#d2"))
        #expect(note.contains("拖了大半年"))
        let layout = await CoreTextPaginator().paginate(spineIndex: 2, attrStr: built.attributedString,
            pageBackgroundImage: built.pageBackgroundImage, renderSize: size, fontSize: settings.fontSize)
        var found = false
        for page in layout.pageRanges.indices {
            let attachments = (layout.inlineAttachments[page] ?? []) + (layout.blockAttachments[page] ?? [])
            for attachment in attachments {
                guard let region = attachment.linkRegions.first(where: { $0.href == "#d2" }) else { continue }
                let point = CGPoint(x: attachment.rect.minX + region.normalizedRect.midX * attachment.rect.width,
                                    y: attachment.rect.minY + region.normalizedRect.midY * attachment.rect.height)
                let target = try #require(attachment.linkTarget(at: point))
                let view = CoreTextPageView(frame: CGRect(origin: .zero, size: size))
                view.configure(layout: layout, pageIndex: page)
                var actual: CGRect?
                view.onFootnoteTap = { text, rect in #expect(text == note); actual = rect }
                view.debugHandleTap(at: point)
                #expect(actual == target.rect)
                #expect(target.rect.width < attachment.rect.width)
                found = true
            }
        }
        #expect(found, "The production table rasterizer must retain the d2 hotspot")
    }
}
