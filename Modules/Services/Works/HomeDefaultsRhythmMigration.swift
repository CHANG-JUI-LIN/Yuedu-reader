import Foundation

/// The 2026-10-25 layouts for a saved 預設 (maintainer, 2026-10-26;
/// `Technotes/AppleBooksHomeLayouts-2026-10-25.md` §8). New installs and 預設配置 have them from
/// `HomePageDefaults`; this gives them to a 預設 made before.
///
/// A saved 預設 holds no mark of whether the reader changed it, nor of whom it was made for, so
/// it is recognised by what it holds:
/// - Its sections, in order, are those `previousDefaults` makes for some mode, region and
///   reading languages: the defaults from 2026-10-13 (a338bbea, 精選書單 one section) to
///   2026-10-25 (c4cd251e), without 為你推薦, which `HomePageStore` takes off first (deleted
///   2026-10-27). An older 預設, or one with a section added, removed or moved, is left as it is.
/// - A section still as those defaults made it takes the layout today's defaults give its
///   binding. One the reader hid, titled, gave a subtitle or parameters, or drew another way
///   keeps what it has.
/// - Layouts only: no section is added, removed or moved, and each keeps its id.
/// - One band on the page: the first untouched list with covers takes it, unless the reader
///   has one already.
///
/// `HomePageStore` runs it once, on 預設 only: the reader's own 首頁配置, those made from 預設配置
/// included, are theirs.
enum HomeDefaultsRhythmMigration {
    /// What became of a 預設 that was recognised.
    struct Outcome: Equatable {
        var sections: [HomeSection]
        /// Sections drawn a new way.
        var changed: Int
        /// Sections the reader had changed, left as they were.
        var kept: Int
    }

    /// Nil when `sections` are not the defaults of 2026-10-13 to 2026-10-25.
    static func apply(to sections: [HomeSection]) -> Outcome? {
        let bindings = sections.map(\.binding)
        for context in contexts {
            let previous = previousDefaults(for: context)
            if previous.map(\.binding) == bindings { return apply(to: sections, previous: previous, context: context) }
        }
        return nil
    }

    private static func apply(to sections: [HomeSection], previous: [HomeSection],
                              context: HomePageDefaults.Context) -> Outcome {
        let untouched = sections.indices.filter { index in
            let section = sections[index]
            return section.layout == previous[index].layout && section.title.isEmpty && section.subtitle.isEmpty
                && section.isEnabled && section.parameters.isEmpty
        }
        let untouchedBindings = Set(untouched.map { sections[$0].binding })
        // Today's layout for each binding, the band among the untouched lists.
        var layouts = Dictionary(HomePageDefaults.page(for: context).sections.map { ($0.binding, $0.layout) },
                                 uniquingKeysWith: { first, _ in first })
        let hasBand = sections.contains { $0.layout == .band }
        let lists = HomePageDefaults.officialModuleLists(
            languages: context.languages, publicLibrariesAvailable: context.publicLibrariesAvailable,
            takesBand: { !hasBand && untouchedBindings.contains(.module(moduleID: $0.moduleID, entryID: $0.entryID)) })
        for list in lists { layouts[.module(moduleID: list.moduleID, entryID: list.entryID)] = list.layout }

        var migrated = sections
        var changed = 0
        for index in untouched {
            guard let layout = layouts[migrated[index].binding], layout != migrated[index].layout else { continue }
            migrated[index].layout = layout
            changed += 1
        }
        return Outcome(sections: migrated, changed: changed, kept: sections.count - untouched.count)
    }

    /// Whom the defaults could have been made for: either mode, with or without the public
    /// libraries, and the reading languages that had lists, in any order (none before
    /// 2026-10-21, when the defaults had no official modules' lists).
    static let contexts: [HomePageDefaults.Context] = {
        var languageOrders: [[String]] = [[]]
        func extend(_ order: [String]) {
            for language in ["zh", "ja", "en"] where !order.contains(language) {
                languageOrders.append(order + [language])
                extend(order + [language])
            }
        }
        extend([])
        return ExploreMode.allCases.flatMap { mode in
            [true, false].flatMap { available in
                languageOrders.map { HomePageDefaults.Context(mode: mode, publicLibrariesAvailable: available, languages: $0) }
            }
        }
    }()

    /// `HomePageDefaults.page` from 2026-10-13 to 2026-10-25, frozen so it still recognises
    /// those homes when the defaults change again: 古騰堡熱門 a plain row, 精選書單 專題集合, the
    /// rankings 圖文資訊清單 with ranks, AniList's lists rows. Their 為你推薦, after 系列下一本, is
    /// left out: it was deleted, and taken off the saved homes, on 2026-10-27.
    static func previousDefaults(for context: HomePageDefaults.Context, makeID: () -> UUID = UUID.init) -> [HomeSection] {
        typealias List = HomePageDefaults.ModuleList
        let continueReading = HomeSection(id: makeID(), layout: .compactReadingCard, binding: .continueReading)
        let nextInSeries = HomeSection(id: makeID(), layout: .row, binding: .nextInSeries)
        let latest = HomeSection(id: makeID(), layout: .row, binding: .latest)
        let popular = context.publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .row, binding: .gutenbergShelf(id: "popular"))]
            : []
        let featured = context.publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .collection, binding: .gutenbergLists)]
            : []
        var lists: [List] = []
        for language in context.languages {
            let wanted: [List] = switch ReadingLanguage.base(of: language) {
            case "zh": [List(moduleID: "bangumi", entryID: "novel-rank", layout: .rankedList),
                        List(moduleID: "bangumi", entryID: "manga-rank", layout: .rankedList)]
            // なろう was hidden where the public libraries are.
            case "ja": context.publicLibrariesAvailable ? [List(moduleID: "narou", entryID: "weekly", layout: .rankedList)] : []
            case "en": [List(moduleID: "anilist", entryID: "trending-novels", layout: .row),
                        List(moduleID: "anilist", entryID: "trending-manga", layout: .row)]
            default: []
            }
            for list in wanted where !lists.contains(list) { lists.append(list) }
        }
        let modules = lists.map {
            HomeSection(id: makeID(), layout: $0.layout, binding: .module(moduleID: $0.moduleID, entryID: $0.entryID))
        }
        switch context.mode {
        case .bookSources:
            return [continueReading, nextInSeries, latest] + modules + popular + featured
        case .publicLibraries:
            return [continueReading, nextInSeries] + modules + popular + featured + [latest]
        }
    }
}
