import Foundation

/// The 2026-11-15 defaults, the store's page with its genres (maintainer, 2026-11-15: 探索更多,
/// 分類瀏覽, 類型 and 之前讀過 after Apple Books' store), for a saved 預設. New installs and 預設配置
/// have them from `HomePageDefaults`; this gives them to a 預設 still as the 2026-11-14 page made
/// it, whole, as `HomeDefaultsStoreMigration` gave that page: sections are added between the
/// others, so they cannot be laid over a home the reader arranged.
///
/// Recognised by what it holds, as the 2026-11-14 migration recognises its page: exactly the
/// sections `storeDefaults` makes for some mode, region and reading languages, each drawn as made,
/// shown, with no title, subtitle or parameters of the reader's. A 預設 still as the defaults
/// before 2026-11-14 made it needs none of this: `HomeDefaultsStoreMigration` runs first and
/// makes today's page for it.
///
/// `HomePageStore` runs it once, on 預設 only.
enum HomeDefaultsGenresMigration {
    /// Whether `sections` are the 2026-11-14 page, untouched.
    static func recognises(_ sections: [HomeSection]) -> Bool {
        HomeDefaultsRhythmMigration.contexts.contains { context in
            let made = storeDefaults(for: context)
            return made.count == sections.count && zip(made, sections).allSatisfy(isAsMade)
        }
    }

    private static func isAsMade(_ made: HomeSection, _ saved: HomeSection) -> Bool {
        saved.binding == made.binding && saved.layout.style == made.layout.style && saved.isEnabled
            && saved.title.isEmpty && saved.subtitle.isEmpty && saved.parameters.isEmpty
    }

    /// 熱門精選's lists on the 2026-11-14 page: 趨勢's 今年熱門, 完結推薦 and 經典名著.
    /// `HomeDefaultsLanguageSwap` knows that page by them too.
    static let storePickCards = ["year", "completed", "classics"].map {
        HomeListCard(binding: .module(moduleID: HomePageDefaults.trendsID, entryID: $0))
    }

    /// `HomePageDefaults.page` of 2026-11-14, frozen so it still recognises that page now that the
    /// defaults have changed.
    static func storeDefaults(for context: HomePageDefaults.Context, makeID: () -> UUID = UUID.init) -> [HomeSection] {
        func trends(_ entry: String, _ layout: HomeSectionLayout) -> HomeSection {
            HomeSection(id: makeID(), layout: layout, binding: .module(moduleID: HomePageDefaults.trendsID, entryID: entry))
        }
        let continueReading = HomeSection(id: makeID(), layout: .compactReadingCard, binding: .continueReading)
        let nextInSeries = HomeSection(id: makeID(), layout: .row, binding: .nextInSeries)
        let latest = HomeSection(id: makeID(), layout: .row, binding: .latest)
        let picks = HomeSection(id: makeID(), layout: .collageCards, binding: .lists(storePickCards))
        let hero = trends("today", .heroCards)
        let trending = trends("month", .multiRow)
        let rankingCards = HomePageDefaults.rankings(languages: context.languages,
                                                     publicLibrariesAvailable: context.publicLibrariesAvailable)
        let charts = rankingCards.isEmpty ? [] : [HomeSection(id: makeID(), layout: .rankedRow, binding: .lists(rankingCards))]
        let explore = context.publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .bannerCards, binding: .gutenbergLists)]
            : []
        let completed = trends("completed", .largeRow)
        let year = trends("year", .heroGrid)
        let classics = trends("classics", .colorBand)
        let popular = context.publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .row, binding: .gutenbergShelf(id: "popular"))]
            : []
        let store = [picks, hero, trending] + charts + explore + [completed, year, classics] + popular
        switch context.mode {
        case .bookSources:
            return [continueReading, nextInSeries, latest] + store
        case .publicLibraries:
            return [continueReading, nextInSeries] + store + [latest]
        }
    }
}
