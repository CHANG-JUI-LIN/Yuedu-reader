import Testing
import UIKit
@testable import yuedu_app

/// The 載入中 page is the one reader surface that is not a `CoreTextPageView`, so it
/// has to reproduce the page canvas by hand. It used to paint a flat theme colour,
/// which read as "the loading page ignores my background" for anyone using a reader
/// background image — every laid-out page around it drew the artwork.
@MainActor
@Suite("Reader loading placeholder background")
struct ReaderLoadingPlaceholderBackgroundTests {

    @Test("placeholder paints the reading theme background")
    func placeholderPaintsThemeBackground() {
        let placeholder = PlaceholderPageViewController(
            chapterTitle: "第一章",
            themeBackgroundColor: .green,
            themeTextColor: .red
        )
        placeholder.loadViewIfNeeded()

        #expect(placeholder.view.backgroundColor == UIColor.green)
        // No artwork configured → no image layer at all.
        #expect(placeholder.view.subviews.contains { $0 is UIImageView } == false)
    }

    @Test("placeholder draws the reader background image beneath its chrome")
    func placeholderDrawsReaderBackgroundImage() throws {
        let image = Self.solidImage(.blue, size: CGSize(width: 4, height: 8))
        let placeholder = PlaceholderPageViewController(
            chapterTitle: "第一章",
            themeBackgroundColor: .green,
            themeTextColor: .red,
            readerBackgroundImage: image
        )
        placeholder.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        placeholder.loadViewIfNeeded()
        placeholder.view.layoutIfNeeded()

        let imageView = try #require(
            placeholder.view.subviews.compactMap { $0 as? UIImageView }.first
        )
        #expect(imageView.image === image)
        // Same geometry `CoreTextPageView.backgroundImageRect` uses, so the artwork
        // does not jump when the real page replaces this one.
        #expect(imageView.contentMode == .scaleAspectFill)
        #expect(imageView.clipsToBounds)
        #expect(imageView.frame == placeholder.view.bounds)
        // Behind the spinner and the chapter title, never over them.
        #expect(placeholder.view.subviews.first === imageView)
    }

    @Test("paged engine hands its reader background image to the placeholder")
    func pagedEngineHandsBackgroundImageToPlaceholder() throws {
        let imageURL = try Self.writeTemporaryImage()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        var settings = Self.renderSettings
        settings.readerBackgroundImageURL = imageURL
        let engine = CoreTextPageEngine(
            attributedBuilder: MockAttributedStringBuilder(texts: ["第一章"]),
            renderSettings: settings,
            offsetStore: CharOffsetStore(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("placeholder-bg-\(UUID().uuidString)")
            )
        )
        engine.applyThemeChange(textColor: .red, backgroundColor: .green)

        // Nothing is laid out yet, so this is the 載入中 page.
        let placeholder = try #require(
            engine.pageViewController(at: 0) as? PlaceholderPageViewController
        )
        placeholder.loadViewIfNeeded()

        #expect(placeholder.view.backgroundColor == UIColor.green)
        #expect(placeholder.view.subviews.contains { ($0 as? UIImageView)?.image != nil })
    }

    // MARK: - Fixtures

    private static var renderSettings: ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 17,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 6,
            letterSpacing: 0,
            marginH: 12,
            marginV: 12,
            footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        )
    }

    private static func solidImage(_ color: UIColor, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func writeTemporaryImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-bg-\(UUID().uuidString).png")
        let data = try #require(solidImage(.blue, size: CGSize(width: 4, height: 8)).pngData())
        try data.write(to: url)
        return url
    }
}
