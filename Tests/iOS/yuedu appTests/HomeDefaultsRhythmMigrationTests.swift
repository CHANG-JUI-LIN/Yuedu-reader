import Foundation
import Testing
@testable import yuedu_app

// The 2026-10-25 layouts for a 預設 saved before them (maintainer, 2026-10-26): a 預設 whose
// sections are the old defaults' is recognised, each section still as they made it takes today's
// layout, and the store does it once, on 預設 only.

private typealias Migration = HomeDefaultsRhythmMigration

private func context(_ languages: [String], mode: ExploreMode = .publicLibraries,
                     libraries: Bool = true) -> HomePageDefaults.Context {
    HomePageDefaults.Context(mode: mode, publicLibrariesAvailable: libraries, languages: languages)
}

private func position(of binding: HomeSectionBinding, in sections: [HomeSection]) throws -> Int {
    try #require(sections.firstIndex { $0.binding == binding })
}

private let popular = HomeSectionBinding.gutenbergShelf(id: "popular")
private let bangumiNovels = HomeSectionBinding.module(moduleID: "bangumi", entryID: "novel-rank")

@Suite("Home defaults rhythm migration")
struct HomeDefaultsRhythmMigrationTests {
    @Test("an untouched old 預設 becomes today's defaults for whom it was made, ids and all")
    func untouched() throws {
        for made in Migration.contexts {
            let saved = Migration.previousDefaults(for: made)
            let outcome = try #require(Migration.apply(to: saved), "\(made)")
            let today = HomePageDefaults.page(for: made).sections
            #expect(outcome.sections.map(\.binding) == today.map(\.binding), "the same sections in the same order: \(made)")
            #expect(outcome.sections.map(\.layout) == today.map(\.layout), "\(made)")
            #expect(outcome.sections.map(\.id) == saved.map(\.id))
            #expect(outcome.kept == 0)
        }
    }

    @Test("a 預設 of 2026-10-13, before the modules' lists: 熱門 ranked, 精選書單 分類卡片, no band")
    func beforeModuleLists() throws {
        let outcome = try #require(Migration.apply(to: Migration.previousDefaults(for: context([]))))
        #expect(outcome.sections.map(\.layout) == [.compactReadingCard, .row, .rankedRow, .categoryCards, .row])
        #expect(outcome.changed == 2)
    }

    @Test("a Chinese 預設 of 2026-10-21: Bangumi's novels the band, its manga ranked")
    func chinese() throws {
        let outcome = try #require(Migration.apply(to: Migration.previousDefaults(for: context(["zh"]))))
        #expect(outcome.sections.map(\.layout)
            == [.compactReadingCard, .row, .band, .rankedRow, .rankedRow, .categoryCards, .row])
        #expect(outcome.changed == 4)
    }

    @Test("several languages: なろう stays a ranked list and never takes the band, and the page has one band")
    func severalLanguages() throws {
        let outcome = try #require(Migration.apply(to: Migration.previousDefaults(for: context(["ja", "en", "zh"], mode: .bookSources))))
        let modules = outcome.sections.filter {
            if case .module = $0.binding { return true }
            return false
        }
        #expect(modules.map(\.layout) == [.rankedList, .band, .heroGrid, .rankedRow, .rankedRow])
        #expect(outcome.sections.filter { $0.layout == .band }.count == 1)
    }

    @Test("a section the reader hid, titled, gave a subtitle or parameters, or drew another way keeps it; the rest change")
    func editedSectionKept() throws {
        let edits: [(name: String, edit: (inout HomeSection) -> Void)] = [
            ("hidden", { $0.isEnabled = false }),
            ("titled", { $0.title = "下載排行" }),
            ("subtitled", { $0.subtitle = "大家都在讀" }),
            ("parameters", { $0.parameters = ["sort": "week"] }),
            ("another layout", { $0.layout = .coverGrid }),
        ]
        for (name, edit) in edits {
            var saved = Migration.previousDefaults(for: context(["zh"]))
            let edited = try position(of: popular, in: saved)
            let lists = try position(of: .gutenbergLists, in: saved)
            let novels = try position(of: bangumiNovels, in: saved)
            edit(&saved[edited])
            let outcome = try #require(Migration.apply(to: saved), "\(name)")
            #expect(outcome.sections[edited] == saved[edited], "\(name)")
            #expect(outcome.sections[lists].layout == .categoryCards, "\(name)")
            #expect(outcome.sections[novels].layout == .band, "\(name)")
            #expect(outcome.changed == 3, "\(name)")
            #expect(outcome.kept == 1, "\(name)")
        }
    }

    @Test("the band goes to the first untouched list with covers when the reader changed the first")
    func bandMoves() throws {
        var saved = Migration.previousDefaults(for: context(["zh"]))
        let novels = try position(of: bangumiNovels, in: saved)
        saved[novels].title = "小說"
        let outcome = try #require(Migration.apply(to: saved))
        #expect(outcome.sections[novels].layout == .rankedList)
        #expect(outcome.sections[novels + 1].layout == .band)
    }

    @Test("a page the reader already gave a band gets no second")
    func noSecondBand() throws {
        var saved = Migration.previousDefaults(for: context(["zh"]))
        let novels = try position(of: bangumiNovels, in: saved)
        saved[novels].layout = .band
        let outcome = try #require(Migration.apply(to: saved))
        #expect(outcome.sections[novels + 1].layout == .rankedRow)
        #expect(outcome.sections.filter { $0.layout == .band }.count == 1)
    }

    @Test("a 預設 with a section added, removed or moved is not recognised")
    func otherPages() {
        let saved = Migration.previousDefaults(for: context(["zh"]))
        var added = saved
        added.append(HomeSection(layout: .row, binding: .bookshelf))
        var removed = saved
        removed.removeAll { $0.binding == .nextInSeries }
        var moved = saved
        moved.swapAt(3, 4)
        for page in [added, removed, moved] { #expect(Migration.apply(to: page) == nil) }
    }

    @Test("a 預設 from before 2026-10-13, a row per 書單, is not recognised")
    func beforeOneListSection() {
        let sections = [HomeSection(layout: .compactReadingCard, binding: .continueReading),
                        HomeSection(layout: .row, binding: .nextInSeries),
                        HomeSection(layout: .row, binding: popular),
                        HomeSection(layout: .row, binding: .gutenbergCollection(id: "chinese")),
                        HomeSection(layout: .row, binding: .gutenbergCollection(id: "mystery")),
                        HomeSection(layout: .row, binding: .latest)]
        #expect(Migration.apply(to: sections) == nil)
    }
}

@Suite("Home defaults rhythm in the store", .serialized)
@MainActor
struct HomeDefaultsRhythmStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HomeDefaultsRhythm-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("explore_home.json")
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "HomeDefaultsRhythm-\(UUID().uuidString)")!
    }

    private func savedHome(_ sections: [HomeSection]) -> URL {
        let url = scratch()
        let store = HomePageStore(fileURL: url)
        store.save(HomePage(sections: sections))
        store.waitForPendingWritesForTesting()
        return url
    }

    private var chinese: HomePageDefaults.Context { context(["zh"]) }

    @Test("an untouched 預設 takes the new layouts at launch, and they are written")
    func migratesAtLaunch() {
        let made = Migration.previousDefaults(for: chinese)
        let url = savedHome(made)
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        store.waitForPendingWritesForTesting()
        #expect(store.page?.sections.map(\.layout) == HomePageDefaults.page(for: chinese).sections.map(\.layout))
        #expect(store.page?.sections.map(\.id) == made.map(\.id))
        #expect(defaults.bool(forKey: HomePageStore.defaultsRhythmKey))
        #expect(HomePageStore(fileURL: url).page == store.page, "the file holds them")
    }

    @Test("once: a reader who puts 熱門 back to 單排 keeps it")
    func once() throws {
        let url = savedHome(Migration.previousDefaults(for: chinese))
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        let edited = try position(of: popular, in: #require(store.page).sections)
        store.edit { $0.sections[edited].layout = .row }
        store.waitForPendingWritesForTesting()
        let reopened = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(reopened.page?.sections[edited].layout == .row)
        #expect(reopened.page?.sections.contains { $0.layout == .band } == true)
    }

    @Test("a new install's defaults count as the one time")
    func newInstall() {
        let url = scratch()
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        _ = store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        // The reader draws every section the way the old defaults did.
        let previous = Migration.previousDefaults(for: chinese)
        store.edit { page in
            for index in page.sections.indices { page.sections[index].layout = previous[index].layout }
        }
        store.waitForPendingWritesForTesting()
        let reopened = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(reopened.page?.sections.map(\.layout) == previous.map(\.layout))
    }

    @Test("預設 only: a 首頁配置 of the reader's own holding the old defaults keeps them, and stays selected")
    func ownConfigurationsKept() throws {
        let old = Migration.previousDefaults(for: chinese)
        let url = savedHome(old)
        let maker = HomePageStore(fileURL: url)
        maker.createConfiguration(named: "我的", from: .blank, defaults: chinese)
        maker.save(HomePage(sections: Migration.previousDefaults(for: chinese)))
        maker.waitForPendingWritesForTesting()
        let own = maker.selectedConfiguration

        let store = HomePageStore(fileURL: url, defaults: suite(), appliesDefaultsRhythmOnce: true)
        #expect(store.selectedConfiguration == own)
        #expect(store.page?.sections.map(\.layout) == old.map(\.layout))
        #expect(store.home?.sections(of: .defaults).map(\.layout) == HomePageDefaults.page(for: chinese).sections.map(\.layout))
    }

    /// 為你推薦 as the builds before 2026-10-27 wrote it.
    private var deletedForYou: HomeSection {
        HomeSection(layout: .row, binding: .unknown(.object(["type": .string("forYou")])))
    }

    @Test("a 預設 that still has 為你推薦, after 系列下一本, has it taken off and is recognised")
    func withDeletedForYou() throws {
        var saved = Migration.previousDefaults(for: chinese)
        saved.insert(deletedForYou, at: try position(of: .nextInSeries, in: saved) + 1)
        let url = savedHome(saved)
        let store = HomePageStore(fileURL: url, defaults: suite(), appliesDefaultsRhythmOnce: true)
        store.waitForPendingWritesForTesting()
        let today = HomePageDefaults.page(for: chinese).sections
        #expect(store.page?.sections.map(\.binding) == today.map(\.binding))
        #expect(store.page?.sections.map(\.layout) == today.map(\.layout))
        #expect(HomePageStore(fileURL: url).page == store.page, "the file holds it")
    }

    @Test("為你推薦, deleted, is taken off 預設 and the reader's own 首頁配置, cards of lists too, and the file is written")
    func deletedForYouTakenOffEverywhere() throws {
        let kept = HomeSection(layout: .row, binding: .bookshelf)
        let card = HomeListCard(binding: .unknown(.object(["type": .string("forYou")])))
        let hot = HomeListCard(binding: .module(moduleID: "m", entryID: "hot"))
        let mixed = HomeSection(layout: .collageCards, binding: .lists([card, hot]))
        let alone = HomeSection(layout: .collageCards, binding: .lists([card]))
        let own = HomeConfigurationID(rawValue: "own")
        let url = scratch()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(HomeConfigurations(
            sections: [deletedForYou, kept],
            configurations: [HomeConfiguration(id: own, name: "我的", sections: [kept, deletedForYou, mixed, alone])])).write(to: url)
        let store = HomePageStore(fileURL: url, defaults: suite())
        store.waitForPendingWritesForTesting()
        #expect(store.home?.sections(of: .defaults) == [kept])
        var cardsLeft = mixed
        cardsLeft.binding = .lists([hot])
        #expect(store.home?.sections(of: own) == [kept, cardsLeft], "a section of lists keeps its other cards, and goes with its last")
        #expect(HomePageStore(fileURL: url).home == store.home, "the file holds it")
    }

    @Test("a newer build's file is only read, and the one time waits for a build that writes")
    func newerBuild() throws {
        let old = Migration.previousDefaults(for: chinese)
        let url = scratch()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var file = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(HomeConfigurations(sections: old)))
            as? [String: Any])
        file["schemaVersion"] = HomePage.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(store.isReadOnly)
        #expect(store.page?.sections.map(\.layout) == old.map(\.layout))
        #expect(!defaults.bool(forKey: HomePageStore.defaultsRhythmKey))
    }

    @Test("a store that does not apply it reads the home as saved")
    func notApplied() {
        let old = Migration.previousDefaults(for: chinese)
        let defaults = suite()
        let store = HomePageStore(fileURL: savedHome(old), defaults: defaults)
        #expect(store.page?.sections == old)
        #expect(!defaults.bool(forKey: HomePageStore.defaultsRhythmKey))
    }
}
