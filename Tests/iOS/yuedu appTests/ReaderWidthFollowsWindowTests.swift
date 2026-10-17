import Combine
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Three places still took a width or height from `UIScreen` instead of from the reader's own
/// window, so in a Stage Manager or Split View window they composed for the screen:
/// the TXT builder's dialogue-bubble column (and chapter-title width), the scroll engine's
/// cap on a full-page image, and the fixed-page reader's image decode width.
@Suite("Reader widths follow the reader's window", .serialized)
struct ReaderWidthFollowsWindowTests {

    // MARK: TXT builder — the width the engine hands it

    @Test(.timeLimit(.minutes(1))) @MainActor
    func txtDialogueBubbleColumnIsTheRenderSizeNotTheScreen() async throws {
        let body = "敘述。\n「你好。」\n結尾。"
        let builder = TXTLazyAttributedStringBuilder(text: body, chapterIndexes: [
            TXTChapterIndex(index: 0, title: "",
                            contentRange: NSRange(location: 0, length: (body as NSString).length))
        ])
        var settings = EPUBTestFixtures.renderSettings()
        settings.dialogueBubbleStyle = ReaderDialogueBubbleStyle(isEnabled: true)

        // A window that is not the screen: narrower than any device's width.
        let window = CGSize(width: 300, height: 600)
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(attributedBuilder: builder, bookIdentifier: UUID().uuidString,
                         renderSize: window, settings: settings)
        for await ready in renderer.$isCoreTextReady.values where ready { break }

        let engine = try #require(renderer.engine as? CoreTextPageEngine)
        let layout = try #require(engine.layouts[0])
        let quote = (layout.attributedString.string as NSString).range(of: "你好")
        try #require(quote.location != NSNotFound)
        let mark = try #require(layout.attributedString.attribute(
            ReaderDialogueBubbleMarker.attributeKey, at: quote.location, effectiveRange: nil
        ) as? ReaderDialogueBubbleMark)
        // The fixture has no content insets, so the column is the whole render width.
        #expect(mark.metrics.columnWidth == window.width,
                "the bubble was composed for a \(mark.metrics.columnWidth)pt column in a \(window.width)pt window")
    }

    // MARK: Scroll engine — a full-page image is capped by the viewport

    @Test(.timeLimit(.minutes(1))) @MainActor
    func scrollImagePageIsCappedByTheViewportNotTheScreen() async throws {
        let tall = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 1200)).image { context in
            UIColor.systemTeal.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 1200))
        }
        let engine = CoreTextScrollEngine(builder: TallImageBuilder(image: tall),
                                          renderSettings: EPUBTestFixtures.renderSettings())

        // A window 400 pt tall — shorter than every device's screen.
        await engine.start(initialChapter: 0, contentWidth: 300, viewportExtent: 400,
                           loadAdjacentChapters: false)

        let chunk = try #require(engine.chunks.first)
        #expect(abs(chunk.height - 320) < 1,
                "the page may be as tall as the viewport less its 80pt of chrome, not as tall as the screen (got \(chunk.height))")
    }

    // MARK: Fixed-page reader — the decode width follows the view

    @Test(.timeLimit(.minutes(1))) @MainActor
    func fixedPageTargetWidthFollowsTheViewAcrossResizes() throws {
        let metadata = FileManager.default.temporaryDirectory
            .appendingPathComponent("width-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: metadata) }
        var book = ReadingBook(title: "Manga", author: "", contentFilename: "")
        book.isOnline = true
        let reader = FixedPageReaderViewController(
            book: book, store: BookStore(metadataFileURL: metadata),
            state: FixedPageReaderState(), chapterFetcher: MockChapterFetcher())

        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        reader.view.layoutIfNeeded()
        #expect(reader.targetWidth == 390)

        // Stage Manager, Split View or a rotation: the same reader, a new width.
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        #expect(reader.targetWidth == 700,
                "the images are still being decoded for the width the reader had when it was installed")
    }
}

private struct TallImageBuilder: AttributedStringBuilding {
    let image: UIImage

    var chapterCount: Int { 1 }
    func chapterTitle(at index: Int) -> String { "Image" }
    func chapterSourceHref(at index: Int) -> String? { "image.xhtml" }
    func chapterDataSize(at index: Int) async -> Int { 1 }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(
            attributedString: NSAttributedString(string: "\u{FFFC}"),
            imagePage: HTMLAttributedStringBuilder.ImagePage(source: "tall.png", image: image),
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
