import Foundation
import Testing
@testable import yuedu_app

@Suite("Premium feature marketing")
struct PremiumFeatureTests {
    @Test("unavailable features stay excluded when highlighted")
    func unavailableFeaturesStayExcludedWhenHighlighted() {
        let features = PremiumFeature.marketedFeatures(highlighting: .alternateAppIcons)

        #expect(!features.contains(.alternateAppIcons))
    }

    @Test("available highlighted feature appears first exactly once")
    func availableHighlightedFeatureAppearsFirstExactlyOnce() {
        let features = PremiumFeature.marketedFeatures(highlighting: .readerBackgroundImport)

        #expect(features.first == .readerBackgroundImport)
        #expect(features.filter { $0 == .readerBackgroundImport }.count == 1)
    }

    @Test("外觀主題 is sold: it gates custom palettes and page backgrounds that ship")
    func themesAreMarketed() {
        #expect(PremiumFeature.marketedFeatures().contains(.readerThemePacks))
    }

    @Test("氣泡設定 is sold on its own row, not as 對話氣泡與高亮")
    func commentStylesAreMarketed() {
        #expect(PremiumFeature.marketedFeatures().contains(.commentStyles))
        #expect(PremiumPillar.pillar(for: .commentStyles) == .comfort)
        #expect(PremiumPitch.pitch(for: .commentStyles) != PremiumPitch.pitch(for: .dialogueHighlight))
    }

    // MARK: - Paywall pillars

    @Test("every marketed feature is sold under a pillar, so the paywall never drops one")
    func everyMarketedFeatureHasAPillar() {
        for feature in PremiumFeature.marketedFeatures() {
            #expect(PremiumPillar.pillar(for: feature) != nil, "\(feature) has no pillar")
        }
        let sold = Set(PremiumPillar.allCases.flatMap { $0.benefits.map(\.feature) })
        #expect(!sold.contains(.alternateAppIcons))
    }

    @Test("the tapped feature's pillar leads; the Pro row keeps the default order")
    func tappedPillarLeads() {
        #expect(PremiumPillar.ordered(leading: .customFonts) == [.comfort, .understanding, .habits, .modules])
        #expect(PremiumPillar.ordered(leading: .touchZoneEditor) == [.habits, .understanding, .comfort, .modules])
        #expect(PremiumPillar.ordered(leading: .moduleImport) == [.modules, .understanding, .comfort, .habits])
        #expect(PremiumPillar.ordered(leading: nil) == PremiumPillar.allCases)
        #expect(PremiumPillar.ordered(leading: .alternateAppIcons) == PremiumPillar.allCases)
    }

    @Test("each marketed feature opens the paywall on its own headline")
    func contextualHeadlines() {
        let generic = PremiumPitch.pitch(for: nil)
        let headlines = PremiumFeature.marketedFeatures().map { PremiumPitch.pitch(for: $0).headlineKey }
        #expect(!headlines.contains(generic.headlineKey))
        #expect(Set(headlines).count == headlines.count)
    }

    @Test("AI is four reasons to pay, and says it needs the reader's own AI service")
    func aiPillar() {
        let ai = PremiumPillar.understanding
        #expect(ai.benefits.filter { $0.feature == .aiReading }.count == 4)
        #expect(ai.noteKey != nil)
        #expect(Set(PremiumPillar.allCases.flatMap { $0.benefits.map(\.id) }).count
            == PremiumPillar.allCases.flatMap(\.benefits).count)
    }

    // MARK: - 新增模組

    @Test("新增模組 is sold as its own group, and says what stays free")
    func modulePillar() {
        #expect(PremiumFeature.marketedFeatures().contains(.moduleImport))
        #expect(PremiumPillar.pillar(for: .moduleImport) == .modules)
        #expect(PremiumPillar.modules.benefits.allSatisfy { $0.feature == .moduleImport })
        #expect(PremiumPillar.modules.noteKey != nil)
    }

    @Test("without Pro a route of 新增模組 opens the paywall: no disclaimer, no sheet, no picker")
    @MainActor
    func addingAModuleNeedsPro() {
        for route in RuleModuleAddRoute.allCases {
            let locked = RuleModuleAddFlow(mayAdd: { false })
            locked.begin(route, clipboard: { nil })
            #expect(locked.showsPaywall, "\(route)")
            #expect(!locked.showsSheet && !locked.showsFileImporter && !locked.showsDisclaimer, "\(route)")

            let open = RuleModuleAddFlow(mayAdd: { true })
            open.begin(route, clipboard: { nil })
            #expect(!open.showsPaywall, "\(route)")
            #expect(open.showsSheet || open.showsFileImporter || open.showsDisclaimer, "\(route)")
        }
    }

    // MARK: - Price framing

    @Test("lifetime is framed in months of the monthly plan, to the half month")
    func lifetimeInMonths() {
        #expect(PaywallPricing.lifetimeInMonths(lifetime: Decimal(string: "14.99")!, monthly: Decimal(string: "1.99")!) == Decimal(string: "7.5"))
        #expect(PaywallPricing.lifetimeInMonths(lifetime: Decimal(string: "9.99")!, monthly: Decimal(string: "1.99")!) == 5)
        #expect(PaywallPricing.lifetimeInMonths(lifetime: 30, monthly: 3) == 10)
    }

    @Test("no framing without two real prices, or when lifetime is cheaper than a month")
    func noFramingWithoutPrices() {
        #expect(PaywallPricing.lifetimeInMonths(lifetime: 14.99, monthly: 0) == nil)
        #expect(PaywallPricing.lifetimeInMonths(lifetime: 0, monthly: 1.99) == nil)
        #expect(PaywallPricing.lifetimeInMonths(lifetime: 1, monthly: 2) == nil)
    }
}
