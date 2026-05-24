import Foundation
import Testing
import UIKit
@testable import yuedu_app

@MainActor
struct CoreTextChapterEndPlaceholderTests {
    @Test("unloaded chapter end estimates the chapter tail instead of chapter start")
    func unloadedChapterEndEstimatesTailPage() async throws {
        let builder = FixedSizeChapterBuilder(byteSizes: [1_200, 1_200, 1_800, 1_800])
        let engine = CoreTextPageEngine(
            attributedBuilder: builder,
            renderSettings: ReaderRenderSettings(
                theme: "test",
                textColor: .label,
                backgroundColor: .systemBackground,
                fontSize: 20,
                lineHeightMultiple: 1.4,
                lineSpacing: 2,
                paragraphSpacing: 8,
                letterSpacing: 0,
                marginH: 20,
                marginV: 20,
                footerHeight: 0,
                contentInsets: .zero,
                writingMode: .horizontal
            ),
            offsetStore: CharOffsetStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("CoreTextChapterEndPlaceholder-\(UUID().uuidString)")
            )
        )

        await engine.start(renderSize: CGSize(width: 320, height: 640), bookId: "chapter-end-test")

        #expect(engine.layouts[2] == nil)
        let chapterStart = engine.pageIndex(forSpine: 2, charOffset: 0)
        let estimatedEnd = try #require(engine.estimatedGlobalPage(for: .chapterEnd(2)))

        #expect(estimatedEnd > chapterStart)

        let placeholder = engine.pageViewController(at: estimatedEnd)
        let position = (placeholder as? CoreTextReadingPositionProviding)?.coreTextReadingPosition
        #expect(position == .chapterEnd(2))
    }

    @Test("page provider exposes previous chapter tail as boundary placeholder")
    func providerReportsBackwardBoundaryPlaceholder() async throws {
        let builder = FixedSizeChapterBuilder(byteSizes: [1_200, 1_200, 1_800])
        let engine = CoreTextPageEngine(
            attributedBuilder: builder,
            renderSettings: ReaderRenderSettings(
                theme: "test",
                textColor: .label,
                backgroundColor: .systemBackground,
                fontSize: 20,
                lineHeightMultiple: 1.4,
                lineSpacing: 2,
                paragraphSpacing: 8,
                letterSpacing: 0,
                marginH: 20,
                marginV: 20,
                footerHeight: 0,
                contentInsets: .zero,
                writingMode: .horizontal
            ),
            offsetStore: CharOffsetStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ReaderBoundaryReadiness-\(UUID().uuidString)")
            )
        )

        await engine.start(renderSize: CGSize(width: 320, height: 640), bookId: "boundary-test")
        let provider = LegacyCoreTextPageProvider(engine: engine, bookId: "boundary-test")
        let readiness = await provider.prepareBoundary(
            from: .chapterStart(3),
            direction: .backward
        )

        guard case .placeholder(let target, let pageIndex) = readiness else {
            Issue.record("Expected placeholder readiness, got \(readiness)")
            return
        }

        #expect(target.coreTextPosition == .chapterEnd(2))
        #expect(pageIndex >= 0)
    }
}

private struct FixedSizeChapterBuilder: AttributedStringBuilding {
    let byteSizes: [Int]

    var chapterCount: Int { byteSizes.count }

    func chapterTitle(at index: Int) -> String {
        "Chapter \(index)"
    }

    func chapterDataSize(at index: Int) async -> Int {
        byteSizes[index]
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        guard byteSizes.indices.contains(index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }
        let text = String(repeating: "字", count: max(1, byteSizes[index] / 3))
        return AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
