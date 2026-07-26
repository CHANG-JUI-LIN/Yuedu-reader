import Testing
@testable import yuedu_app

@Suite("Premium feature marketing")
struct PremiumFeatureTests {
    @Test("unavailable features stay excluded when highlighted")
    func unavailableFeaturesStayExcludedWhenHighlighted() {
        let features = PremiumFeature.marketedFeatures(highlighting: .readerThemePacks)

        #expect(!features.contains(.readerThemePacks))
        #expect(!features.contains(.alternateAppIcons))
    }

    @Test("available highlighted feature appears first exactly once")
    func availableHighlightedFeatureAppearsFirstExactlyOnce() {
        let features = PremiumFeature.marketedFeatures(highlighting: .readerBackgroundImport)

        #expect(features.first == .readerBackgroundImport)
        #expect(features.filter { $0 == .readerBackgroundImport }.count == 1)
    }
}
