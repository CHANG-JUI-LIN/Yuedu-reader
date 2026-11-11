@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// FB-178: reaching for the top-right corner while the controls were up, a reader tapped the
/// status bar, and the page rolled back to the start of chapter 1. That was UIKit's
/// scroll-to-top, which every scroll view takes by default. No reading page may answer it:
/// the strip and the scrolling book both hold chapters from before the one being read.
@MainActor
struct ReaderStatusBarTapTests {
    @Test func aWebtoonIgnoresAStatusBarTap() {
        let width = FixedPageTargetWidth()
        width.value = 402
        let reader = FixedPageWebtoonViewController(
            fixedPageReaderConfiguration: .recommendedDefault(for: .webtoon), targetWidth: width
        )
        reader.loadViewIfNeeded()
        #expect(Self.scrollViewsTakingStatusBarTaps(in: reader.view) == [])
    }

    @Test(arguments: [CoreTextScrollAxis.vertical, .horizontalRTL])
    func aScrollingBookIgnoresAStatusBarTap(axis: CoreTextScrollAxis) {
        let engine = CoreTextScrollEngine(
            builder: StatusBarTestBuilder(chapters: ["第一章", "第二章"]),
            renderSettings: ReaderRenderSettings(
                theme: "test",
                textColor: .black,
                backgroundColor: .white,
                fontSize: 18,
                lineHeightMultiple: 1.0,
                lineSpacing: 0,
                paragraphSpacing: 0,
                letterSpacing: 0,
                marginH: 0,
                marginV: 0,
                footerHeight: 0,
                contentInsets: .zero,
                writingMode: axis == .vertical ? .horizontal : .verticalRTL
            )
        )
        let reader = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: axis,
            sideInsets: .init(left: 12, right: 12),
            verticalInset: 20,
            backgroundColor: .white
        )
        reader.loadViewIfNeeded()
        #expect(Self.scrollViewsTakingStatusBarTaps(in: reader.view) == [])
    }

    /// Every scroll view in `view`'s tree that would scroll to its top on a status bar tap.
    private static func scrollViewsTakingStatusBarTaps(in view: UIView) -> [String] {
        var found: [String] = []
        if let scrollView = view as? UIScrollView, scrollView.scrollsToTop {
            found.append(String(describing: type(of: scrollView)))
        }
        for subview in view.subviews {
            found += scrollViewsTakingStatusBarTaps(in: subview)
        }
        return found
    }
}

private struct StatusBarTestBuilder: AttributedStringBuilding {
    let chapters: [String]

    var chapterCount: Int { chapters.count }

    func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
    func chapterSourceHref(at index: Int) -> String? { "chapter-\(index).xhtml" }
    func chapterDataSize(at index: Int) async -> Int { chapters[index].utf8.count }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: chapters[index],
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
