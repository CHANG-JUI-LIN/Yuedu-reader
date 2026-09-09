import Testing
import UIKit
@testable import yuedu_app

private let phase4F0ProductionEPUBRunMarker = "/tmp/yuedu-run-phase4f0-production-epub"

/// Local production-corpus acceptance for the EPUB that exposed the shared
/// Legacy/Browser frontend defect. It is marker-gated because the publication
/// is a user-owned desktop fixture and is intentionally not checked into git.
@MainActor
@Suite(
    "HTML presentational hints production EPUB",
    .serialized,
    .enabled(if: FileManager.default.fileExists(atPath: phase4F0ProductionEPUBRunMarker))
)
struct HTMLPresentationalHintProductionEPUBTests {
    private static let epubPath = "/Users/zhangruilin/Desktop/Test document/EPUB Format/《诡秘之主4》作者：爱潜水的乌贼.epub"
    private static let spineIndex = 5
    private static let contentWidth: CGFloat = 418

    @Test func gm3WidthHintReachesBothProductionPipelines() async throws {
        let session = try await PublicationSession.open(
            sourceURL: URL(fileURLWithPath: Self.epubPath)
        )
        #expect(session.chapters[Self.spineIndex].title == "塔罗会 克莱恩·莫雷蒂 0 The Fool.愚者")
        #expect(session.chapters[Self.spineIndex].href == "OEBPS/Text/tlh001.xhtml")

        let html = try await session.chapterHTML(at: Self.spineIndex)
        #expect(html.contains(#"src="../Images/gm3.png""#))
        #expect(html.contains(#"width="15%""#))

        let adapter = EPUBBrowserLayoutResourceAdapter(session: session)
        let css = await adapter.processedCSS(forChapter: Self.spineIndex)
        let images = await adapter.prefetchImages(
            forChapter: Self.spineIndex,
            html: html,
            renderWidth: Self.contentWidth
        )
        let sourceImage = try #require(images["../Images/gm3.png"])
        #expect(sourceImage.size == CGSize(width: 800, height: 800))

        let browserDocument = BrowserLayoutDocument(
            html: html,
            cssTexts: css,
            config: BrowserLayoutConfig(
                renderWidth: Self.contentWidth,
                renderHeight: 2_200,
                rootFontSize: 17,
                fontFamilies: [],
                textColor: .black,
                backgroundColor: .white,
                contentInsets: .zero,
                lineHeight: 1.4,
                fontResolver: adapter.fontResolver()
            ),
            imageLoader: { images[$0] }
        )
        let browserPages = try await browserDocument.renderPages(
            containerSize: CGSize(width: Self.contentWidth, height: 2_200)
        )
        let browserImage = try #require(
            BrowserLayoutTestSupport.allImageFragments(browserPages)
                .first { $0.source == "../Images/gm3.png" }
        )
        // This fixture authors body margins of 1% on each side. The image's
        // 15% hint resolves against that content box, not the 418pt viewport.
        // Legacy's separate image pipeline retains its own 62.7pt expectation.
        let expectedBrowserImageSize = Self.contentWidth * (1 - 0.01 - 0.01) * 0.15
        #expect(abs(browserImage.rect.width - expectedBrowserImageSize) < 0.1)
        #expect(abs(browserImage.rect.height - expectedBrowserImageSize) < 0.1)

        let legacyBuilder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: Self.contentWidth, height: 2_200)
        )
        let legacyResult = try await legacyBuilder.buildChapter(
            at: Self.spineIndex,
            settings: EPUBTestFixtures.renderSettings(
                fontSize: 17,
                lineHeightMultiple: 1.4,
                paragraphSpacing: 6
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let legacyImage = try #require(
            EPUBTestFixtures.imageRunInfos(in: legacyResult.attributedString)
                .first { $0.info.source == "../Images/gm3.png" }
        )
        #expect(legacyImage.info.image?.size == CGSize(width: 800, height: 800))
        #expect(abs(legacyImage.info.drawWidth - 62.7) < 0.1)
        #expect(abs(legacyImage.info.drawHeight - 62.7) < 0.1)
    }
}
