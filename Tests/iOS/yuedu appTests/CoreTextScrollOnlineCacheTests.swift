import Combine
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct CoreTextScrollOnlineCacheTests {
    @Test("scroll engine requests uncached online chapter then retries insertion after cache is ready")
    func requestsMissingChapterAndRetriesAfterReady() async throws {
        let builder = MutableOnlineLikeBuilder(chapterCount: 2)
        builder.cachedChapters[1] = "Next chapter body"
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .label,
            backgroundColor: .systemBackground,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 2,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 20,
            marginV: 20,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
        let engine = CoreTextScrollEngine(builder: builder, renderSettings: settings)
        var requestedChapters: [Int] = []
        engine.onChapterContentRequired = { requestedChapters.append($0) }

        await engine.start(initialChapter: 1, contentWidth: 320)

        #expect(requestedChapters == [0])
        // An uncached chapter now occupies its slot with a 載入中 placeholder instead of
        // contributing nothing, so it has a range but not its body.
        #expect(engine.chapterRanges[0] != nil)
        #expect(!renderedText(in: engine).contains("Previous chapter body"))
        #expect(engine.chapterRanges[1] != nil)

        builder.cachedChapters[0] = "Previous chapter body"
        let didRetry = await engine.retryChapterIfNeeded(0)

        #expect(didRetry)
        #expect(engine.chapterRanges[0] != nil)
        #expect(engine.chunks.first?.chapterIndex == 0)
        #expect(renderedText(in: engine).contains("Previous chapter body"))
    }

    @Test("arriving chapter content takes its placeholder's slot instead of an end")
    func arrivingChapterReplacesPlaceholderInPlace() async throws {
        // Both chapters start uncached, so both are appended as placeholders in order.
        // Chapter 0 was first requested with `prepend == false`; re-deriving head/tail
        // from that flag appended its body *after* chapter 1's placeholder, which is how
        // the reader ended up showing chapter 2 above chapter 1.
        let builder = MutableOnlineLikeBuilder(chapterCount: 2)
        let engine = CoreTextScrollEngine(
            builder: builder,
            renderSettings: makeSettings()
        )

        await engine.start(initialChapter: 0, contentWidth: 320)

        #expect(engine.chunks.first?.chapterIndex == 0)
        #expect(engine.chunks.last?.chapterIndex == 1)

        builder.cachedChapters[0] = "First chapter body"
        let didRetry = await engine.retryChapterIfNeeded(0)

        #expect(didRetry)
        let firstRange = try #require(engine.chapterRanges[0])
        let secondRange = try #require(engine.chapterRanges[1])
        #expect(firstRange.upperBound <= secondRange.lowerBound)
        #expect(engine.chunks.first?.chapterIndex == 0)
        #expect(renderedText(in: engine).contains("First chapter body"))
    }

    @Test("refreshing a loaded scroll chapter replaces its rendered content")
    func refreshingLoadedChapterReplacesRenderedContent() async throws {
        let builder = MutableOnlineLikeBuilder(chapterCount: 1)
        builder.cachedChapters[0] = "Old chapter body"
        let engine = CoreTextScrollEngine(
            builder: builder,
            renderSettings: makeSettings()
        )
        let expectedPosition = CoreTextReadingPosition(
            spineIndex: 0,
            charOffset: 4
        )
        var restoredPosition: CoreTextReadingPosition?
        let eventCancellable = engine.events.sink { event in
            if case .reset(let position) = event {
                restoredPosition = position
            }
        }
        defer { eventCancellable.cancel() }

        await engine.start(initialChapter: 0, contentWidth: 320)
        #expect(renderedText(in: engine).contains("Old chapter body"))

        builder.cachedChapters[0] = "New chapter body"
        await engine.refreshChapter(
            at: 0,
            restoreAt: expectedPosition
        )

        let refreshedText = renderedText(in: engine)
        #expect(refreshedText.contains("New chapter body"))
        #expect(!refreshedText.contains("Old chapter body"))
        #expect(restoredPosition == expectedPosition)
    }

    private func makeSettings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .label,
            backgroundColor: .systemBackground,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 2,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 20,
            marginV: 20,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
    }

    private func renderedText(in engine: CoreTextScrollEngine) -> String {
        engine.chunks
            .map(\.attributedString.string)
            .joined(separator: "\n")
    }
}

private final class MutableOnlineLikeBuilder: AttributedStringBuilding {
    let chapterCount: Int
    var cachedChapters: [Int: String] = [:]

    init(chapterCount: Int) {
        self.chapterCount = chapterCount
    }

    func chapterTitle(at index: Int) -> String {
        "Chapter \(index)"
    }

    func chapterDataSize(at index: Int) async -> Int {
        cachedChapters[index]?.lengthOfBytes(using: .utf8) ?? 0
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        guard index >= 0, index < chapterCount else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }
        guard let body = cachedChapters[index] else {
            throw AttributedStringBuildingError.contentNotCached(index)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = settings.fontSize * settings.lineHeightMultiple
        paragraph.maximumLineHeight = settings.fontSize * settings.lineHeightMultiple

        return AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: "\(chapterTitle(at: index))\n\(body)\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                    .paragraphStyle: paragraph
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
