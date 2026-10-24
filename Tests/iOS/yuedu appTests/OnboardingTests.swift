import Foundation
import Testing
@testable import yuedu_app

@Suite("新手導覽", .serialized)
@MainActor
struct OnboardingTests {
    @Test func upUntilLeftThenOnlyOnReplay() throws {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = OnboardingState(defaults: defaults)
        #expect(state.isPresented)
        state.finish(startingAt: nil)
        #expect(!state.isPresented)
        #expect(state.pendingStart == nil)
        // Once on a device: the next launch starts on the tabs.
        #expect(!OnboardingState(defaults: defaults).isPresented)
        state.replay()
        #expect(state.isPresented)
    }

    @Test func aStartOpensItsPageOnceAndOnlyThere() throws {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = OnboardingState(defaults: defaults)
        state.finish(startingAt: .connectLibrary)
        #expect(!state.isPresented)
        #expect(state.pendingStart == .connectLibrary)
        #expect(!state.take(.importFiles))
        #expect(state.take(.connectLibrary))
        #expect(state.pendingStart == nil)
        #expect(!state.take(.connectLibrary))
        #expect(!OnboardingState(defaults: defaults).isPresented)
    }

    /// 新增來源配置 and 連接書庫 both open a page on 資源庫: asking for one leaves the other.
    @Test func theLibraryTabsStartsAreTakenApart() throws {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = OnboardingState(defaults: defaults)
        state.replay()
        state.finish(startingAt: .addSources)
        #expect(!state.take(.connectLibrary))
        #expect(state.take(.addSources))
        #expect(state.pendingStart == nil)
    }

    @Test func exploreIsItsTabAlone() throws {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = OnboardingState(defaults: defaults)
        state.finish(startingAt: .explore)
        #expect(state.pendingStart == nil)
        #expect(OnboardingStart.explore.tab == .explore)
        #expect(OnboardingStart.addSources.tab == .library)
        #expect(OnboardingStart.connectLibrary.tab == .library)
        #expect(OnboardingStart.importFiles.tab == .bookshelf)
    }

    @Test func publicLibrariesNamedOnlyWhereTheStorefrontOffersThem() {
        let named = ["Project Gutenberg", "青空文庫", "小説家になろう"]
        let available = makeContent(librariesAvailable: true).sources.rows.map(\.textKey)
        let unavailable = makeContent(librariesAvailable: false).sources.rows.map(\.textKey)
        #expect(named.allSatisfy { name in available.contains { $0.contains(name) } })
        #expect(!named.contains { name in unavailable.contains { $0.contains(name) } })
    }

    /// As `HomePageDefaults` makes a new home: Bangumi's in Chinese, AniList's in English,
    /// なろう's in Japanese where it is offered, none in Korean.
    @Test func rankingsNamedOnlyWhereANewHomeHasThem() {
        let ranked = "打開探索，就有依你的語言排好的排行。各處的書排在同一頁，不分本機或線上。"
        #expect(makeContent(languages: ["zh"]).explore?.textKey == ranked)
        #expect(makeContent(languages: ["en"]).explore?.textKey == ranked)
        #expect(makeContent(languages: ["ja"]).explore?.textKey == ranked)
        #expect(makeContent(librariesAvailable: false, languages: ["ja"]).explore?.textKey
            == "探索是你的首頁，各處的書排在同一頁，不分本機或線上。")
        #expect(makeContent(languages: ["ko"]).explore?.textKey == "探索是你的首頁，各處的書排在同一頁，不分本機或線上。")
        // A later language's rankings count as well.
        #expect(makeContent(languages: ["ko", "zh"]).explore?.textKey == ranked)
    }

    @Test func everyPageAndStartWhenAllTabsAreShown() {
        let content = makeContent()
        #expect(content.pages == OnboardingPage.allCases)
        #expect(content.starts == [.explore, .addSources, .connectLibrary, .importFiles])
        #expect(content.explore?.rows.map(\.titleKey) == ["為你推薦", "最新", "編輯首頁"])
        #expect(content.works.map(\.titleKey) == ["搜索", "作品詳情", "自動補齊書籍資料", "聚合設定"])
        #expect(content.sources.textKey == "來源配置、模組和遠端書庫都在資源庫，加進來就跟內建的一起用。")
    }

    @Test func hiddenTabsAreNeitherWalkedThroughNorOffered() {
        let content = makeContent(visibleTabs: [.bookshelf, .settings])
        #expect(content.pages == [.welcome, .works, .sources, .reading, .start])
        #expect(content.explore == nil)
        #expect(content.starts == [.importFiles])
        #expect(content.works.map(\.titleKey) == ["作品詳情", "自動補齊書籍資料", "聚合設定"])
        #expect(content.sources.textKey == "加進來的來源配置、模組和遠端書庫，跟內建的一起用。")
    }

    @Test func noStartLeavesNoStartPage() {
        let content = makeContent(visibleTabs: [.settings, .search])
        #expect(content.starts.isEmpty)
        #expect(content.pages == [.welcome, .works, .sources, .reading])
    }

    @Test func proFeaturesCarryTheLockUntilBought() {
        let free = makeContent(lockedFeatures: Set(PremiumFeature.allCases)).reading
        #expect(free.map(\.titleKey) == ["劃線與書籤", "聽書", "自動閱讀", "外觀主題", "底部 Tab"])
        #expect(free.map(\.isLocked) == [false, false, false, true, true])

        let pro = makeContent(lockedFeatures: []).reading
        #expect(pro.map(\.titleKey) == free.map(\.titleKey))
        #expect(pro.map(\.isLocked) == [false, false, false, false, false])
    }

    @Test func theShelfFindsEveryCover() {
        #expect(OnboardingCoverShelf.books.map(\.cover)
            == ["midaregami", "little-nemo", "pride-and-prejudice", "cocorico-1898", "panghuang"])
        // The work in front of its versions is one of them.
        #expect(OnboardingCoverShelf.books.contains { $0.cover == OnboardingWorkStack.cover })
    }

    private func makeContent(
        visibleTabs: [RootTabItem] = RootTabItem.tabs,
        librariesAvailable: Bool = true,
        languages: [String] = ["zh"],
        lockedFeatures: Set<PremiumFeature> = Set(PremiumFeature.allCases)
    ) -> OnboardingContent {
        OnboardingContent(
            visibleTabs: visibleTabs,
            librariesAvailable: librariesAvailable,
            languages: languages,
            lockedFeatures: lockedFeatures
        )
    }
}
