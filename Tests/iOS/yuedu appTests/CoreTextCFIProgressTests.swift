import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("CoreText EPUB locator compatibility", .serialized)
struct CoreTextCFIProgressTests {
    private struct StaticChapterBuilder: AttributedStringBuilding {
        let text: String

        var chapterCount: Int { 1 }

        func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
        func chapterSourceHref(at index: Int) -> String? { "Text/chapter.xhtml" }
        func chapterDataSize(at index: Int) async -> Int { text.utf8.count }
        func chapterIndex(for href: String) -> Int? {
            href == "Text/chapter.xhtml" ? 0 : nil
        }

        func buildChapter(
            at index: Int,
            settings: ReaderRenderSettings,
            themeTextColor: UIColor,
            themeBackgroundColor: UIColor
        ) async throws -> AttributedChapterBuildResult {
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                    .backgroundColor: themeBackgroundColor,
                ]
            )
            return AttributedChapterBuildResult(
                attributedString: attributed,
                imagePage: nil,
                pageBackgroundImage: nil,
                anchorOffsets: [:]
            )
        }
    }

    @Test @MainActor func coreTextEPUBStartIgnoresLegacyCFIProgressAfterLayoutChanges() async throws {
        let text = Self.longChapterText()
        let oldSettings = Self.renderSettings(fontSize: 18)
        let newSettings = Self.renderSettings(fontSize: 26)
        let oldSize = CGSize(width: 360, height: 560)
        let newSize = CGSize(width: 360, height: 430)

        let oldLayout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: Self.attributed(text: text, fontSize: oldSettings.fontSize),
            renderSize: oldSize,
            fontSize: oldSettings.fontSize,
            contentInsets: oldSettings.contentInsets
        )
        try #require(oldLayout.pageRanges.count > 3)
        let oldPageIndex = 3
        let cfiCharOffset = Int(oldLayout.pageRanges[oldPageIndex].location)
        try #require(cfiCharOffset > 0)

        let bookId = "CoreTextCFIProgress-\(UUID().uuidString)"
        let documentsURL = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let progressDirectory = documentsURL.appendingPathComponent("epub_progress/\(bookId)")
        try? FileManager.default.removeItem(at: progressDirectory)
        defer { try? FileManager.default.removeItem(at: progressDirectory) }

        let staleLayoutLocator = ReaderLocator(
            spineHref: "Text/chapter.xhtml",
            chapterIndex: 0,
            pageInChapter: 0,
            totalPagesInChapter: oldLayout.pageRanges.count,
            globalPage: 0,
            progression: 0,
            generationId: 0,
            title: "Chapter 0",
            chapterProgression: 0,
            totalProgression: 0,
            partialCFI: "/6/2[yuedu-spine-0]!/4/1:\(cfiCharOffset)"
        )
        let locatorStore = EPUBProgressStore(directoryURL: progressDirectory, debounceInterval: 0)
        locatorStore.save(record: staleLayoutLocator)
        locatorStore.flushSync()

        let offsetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextCFIProgressOffsets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: offsetDirectory) }
        let engine = CoreTextPageEngine(
            attributedBuilder: StaticChapterBuilder(text: text),
            renderSettings: newSettings,
            offsetStore: CharOffsetStore(directoryURL: offsetDirectory)
        )

        await engine.start(renderSize: newSize, bookId: bookId)

        let newLayout = try #require(engine.layouts[0])
        let expectedPage = newLayout.pageIndex(for: cfiCharOffset)
        #expect(expectedPage > 0)
        #expect(engine.currentPage == 0)
    }

    @Test func partialCFIRoundTripsStableReadingPosition() {
        let text = Self.longChapterText()
        let charOffset = text.utf16.count / 2
        let cfi = EPUBPartialCFI.make(spineIndex: 4, charOffset: charOffset)
        let locator = ReaderLocator(
            spineHref: "Text/chapter.xhtml",
            chapterIndex: 0,
            pageInChapter: 0,
            totalPagesInChapter: 1,
            globalPage: 0,
            progression: 0,
            generationId: 0,
            partialCFI: cfi
        )

        #expect(locator.cfiReadingPosition() == CoreTextReadingPosition(spineIndex: 4, charOffset: charOffset))
        #expect(locator.cfiReadingPosition(resolvedChapterIndex: 7) == CoreTextReadingPosition(spineIndex: 7, charOffset: charOffset))
    }

    private static func longChapterText() -> String {
        (0..<180).map { index in
            "第\(index)段，這是一段用來測試 EPUB CoreText CFI 進度恢復的正文。版面改變時頁碼會移動，但文字位置應該保持穩定。"
        }.joined(separator: "\n")
    }

    private static func attributed(text: String, fontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: fontSize)]
        )
    }

    private static func renderSettings(fontSize: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "light",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: 1.4,
            lineSpacing: 4,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 16,
            contentInsets: UIEdgeInsets(top: 24, left: 24, bottom: 48, right: 24)
        )
    }
}
