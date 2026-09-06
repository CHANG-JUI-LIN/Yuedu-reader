import Foundation
import Testing
@testable import yuedu_app

struct FixedPageReaderConfigurationTests {
    @Test("reading formats provide recommended fixed page reader defaults")
    func readingFormatsProvideRecommendedDefaults() {
        let rtl = FixedPageReadingMode.rtl.recommendedConfiguration
        #expect(rtl.layout == .paged)
        #expect(rtl.navigationAxis == .horizontal)
        #expect(rtl.progression == .rightToLeft)
        #expect(rtl.fitMode == .fitPage)
        #expect(rtl.pageSpacing == 8)
        #expect(rtl.isZoomEnabled)

        let ltr = FixedPageReadingMode.ltr.recommendedConfiguration
        #expect(ltr.layout == .paged)
        #expect(ltr.navigationAxis == .horizontal)
        #expect(ltr.progression == .leftToRight)
        #expect(ltr.fitMode == .fitPage)
        #expect(ltr.pageSpacing == 8)
        #expect(ltr.isZoomEnabled)

        let vertical = FixedPageReadingMode.vertical.recommendedConfiguration
        #expect(vertical.layout == .paged)
        #expect(vertical.navigationAxis == .vertical)
        #expect(vertical.progression == .topToBottom)
        #expect(vertical.fitMode == .fitPage)
        #expect(vertical.pageSpacing == 8)
        #expect(vertical.isZoomEnabled)

        let webtoon = FixedPageReadingMode.webtoon.recommendedConfiguration
        #expect(webtoon.layout == .continuousVerticalScroll)
        #expect(webtoon.navigationAxis == .vertical)
        #expect(webtoon.progression == .verticalScroll)
        #expect(webtoon.fitMode == .fitWidth)
        #expect(webtoon.pageSpacing == 0)
        #expect(webtoon.isZoomEnabled)
        #expect(webtoon.pageSpreadLayout == .single)
        #expect(!webtoon.splitWideImages)
        #expect(!webtoon.cropBorders)
        #expect(!webtoon.pillarbox)
        #expect(webtoon.pillarboxAmount == 0.75)
        #expect(webtoon.autoScrollSpeed == 3)
        #expect(webtoon.isLiveTextEnabled)
    }

    @Test("fixed page reader mode keeps legacy manga reading mode fallback")
    func fixedPageReaderModeKeepsLegacyFallback() {
        let suiteName = "test.fixed-page-reader-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bookId = UUID()
        defaults.set(
            FixedPageReadingMode.webtoon.rawValue,
            forKey: "manga.readingMode.\(bookId.uuidString)"
        )

        #expect(FixedPageReadingMode.saved(for: bookId, defaults: defaults) == .webtoon)

        FixedPageReadingMode.save(.ltr, for: bookId, defaults: defaults)

        #expect(FixedPageReadingMode.saved(for: bookId, defaults: defaults) == .ltr)
        #expect(
            defaults.object(forKey: "fixedPage.readingMode.\(bookId.uuidString)") as? Int
                == FixedPageReadingMode.ltr.rawValue
        )
    }
}
