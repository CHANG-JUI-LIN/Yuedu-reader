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
        #expect(!webtoon.isLiveTextEnabled)
        #expect(!rtl.isLiveTextEnabled)
        #expect(!ltr.isLiveTextEnabled)
        #expect(!vertical.isLiveTextEnabled)
    }

    @Test("legacy settings without a Live Text choice default to disabled")
    func missingLiveTextChoiceDefaultsToDisabled() throws {
        let data = try JSONEncoder().encode(FixedPageReadingMode.rtl.recommendedConfiguration)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "isLiveTextEnabled")
        let decoded = try JSONDecoder().decode(
            FixedPageReaderConfiguration.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(!decoded.isLiveTextEnabled)
    }

    @Test("an explicit Live Text choice survives saved settings", arguments: [false, true])
    func explicitLiveTextChoiceIsPreserved(enabled: Bool) throws {
        var configuration = FixedPageReadingMode.webtoon.recommendedConfiguration
        configuration.isLiveTextEnabled = enabled
        let decoded = try JSONDecoder().decode(
            FixedPageReaderConfiguration.self, from: JSONEncoder().encode(configuration)
        )
        #expect(decoded.isLiveTextEnabled == enabled)
    }
}
