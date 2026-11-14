import Foundation
import Testing
@testable import yuedu_app

// The 2026-11-14 page, the home after Apple Books' store, for a 預設 saved before it (maintainer,
// 2026-11-14: 「沒改過的才換」): a 預設 still exactly as the defaults of 2026-10-25 to 2026-11-14
// made it becomes today's page, whole, once; any other is the reader's and stays.

private typealias Migration = HomeDefaultsStoreMigration

private func context(_ languages: [String], mode: ExploreMode = .publicLibraries,
                     libraries: Bool = true) -> HomePageDefaults.Context {
    HomePageDefaults.Context(mode: mode, publicLibrariesAvailable: libraries, languages: languages)
}

private func position(of binding: HomeSectionBinding, in sections: [HomeSection]) throws -> Int {
    try #require(sections.firstIndex { $0.binding == binding })
}

private let popular = HomeSectionBinding.gutenbergShelf(id: "popular")
private let bangumiNovels = HomeSectionBinding.module(moduleID: "bangumi", entryID: "novel-rank")

@Suite("Home defaults store migration")
struct HomeDefaultsStoreMigrationTests {
    @Test("the untouched defaults of 2026-10-25 to 2026-11-14 are recognised, whomever they were made for")
    func untouched() {
        for made in HomeDefaultsRhythmMigration.contexts {
            #expect(Migration.recognises(Migration.previousDefaults(for: made)), "\(made)")
        }
    }

    @Test("an older 預設 is recognised once it has the 2026-10-25 layouts")
    func afterTheRhythm() throws {
        for made in HomeDefaultsRhythmMigration.contexts {
            let old = HomeDefaultsRhythmMigration.previousDefaults(for: made)
            let restyled = try #require(HomeDefaultsRhythmMigration.apply(to: old)).sections
            #expect(Migration.recognises(restyled), "\(made)")
        }
    }

    @Test("a 預設 the reader changed is theirs: a section hidden, titled, given a subtitle or parameters, drawn another way, added, removed or moved")
    func changed() throws {
        let made = Migration.previousDefaults(for: context(["zh"]))
        let novels = try position(of: bangumiNovels, in: made)
        var hidden = made
        hidden[novels].isEnabled = false
        var titled = made
        titled[0].title = "正在讀"
        var subtitled = made
        subtitled[novels].subtitle = "每週更新"
        var filtered = made
        filtered[novels].parameters = ["offset": "20"]
        var redrawn = made
        redrawn[try position(of: popular, in: made)].layout = .row
        let added = made + [HomeSection(layout: .row, binding: .bookshelf)]
        var removed = made
        removed.remove(at: novels)
        var moved = made
        moved.swapAt(0, 1)
        for (name, sections) in [("hidden", hidden), ("titled", titled), ("subtitled", subtitled), ("filtered", filtered),
                                 ("redrawn", redrawn), ("added", added), ("removed", removed), ("moved", moved)] {
            #expect(!Migration.recognises(sections), "\(name)")
        }
        #expect(!Migration.recognises([]))
        // Today's own page is not one to change again.
        #expect(!Migration.recognises(HomePageDefaults.page(for: context(["zh"])).sections))
    }

    @Test("the band the reader picked 大型封面書架 for again looks as it did, and still counts as untouched")
    func bandDrawnAsItWas() throws {
        var made = Migration.previousDefaults(for: context(["zh"]))
        let novels = try position(of: bangumiNovels, in: made)
        #expect(made[novels].layout == .band)
        made[novels].layout = .largeRow
        #expect(Migration.recognises(made))
    }
}

@Suite("Home defaults store migration in the store", .serialized)
@MainActor
struct HomeDefaultsStoreMigrationStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HomeDefaultsStore-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("explore_home.json")
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "HomeDefaultsStore-\(UUID().uuidString)")!
    }

    private func savedHome(_ sections: [HomeSection]) -> URL {
        let url = scratch()
        let store = HomePageStore(fileURL: url)
        store.save(HomePage(sections: sections))
        store.waitForPendingWritesForTesting()
        return url
    }

    private func page(_ store: HomePageStore, _ context: HomePageDefaults.Context) -> HomePage {
        store.pageOrDefaults(mode: context.mode, publicLibrariesAvailable: context.publicLibrariesAvailable,
                             languages: context.languages)
    }

    private var chinese: HomePageDefaults.Context { context(["zh"]) }

    @Test("an untouched 預設 becomes today's page when the home first reads it, once, and the file holds it")
    func migratesOnce() throws {
        let url = savedHome(Migration.previousDefaults(for: chinese))
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        let today = HomePageDefaults.page(for: chinese).sections
        let shown = page(store, chinese)
        #expect(shown.sections.map(\.binding) == today.map(\.binding))
        #expect(shown.sections.map(\.layout) == today.map(\.layout))
        #expect(defaults.bool(forKey: HomePageStore.defaultsStoreKey))
        #expect(store.home?.defaultsLanguages == ["zh"])
        store.waitForPendingWritesForTesting()
        #expect(HomePageStore(fileURL: url).page == shown, "the file holds it")

        // The reader puts the old ranking back as a section of its own: theirs from now on.
        store.edit { $0.sections.append(HomeSection(layout: .rankedRow, binding: bangumiNovels)) }
        store.waitForPendingWritesForTesting()
        let again = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(page(again, chinese).sections.last?.binding == bangumiNovels)
    }

    @Test("a 預設 older than 2026-10-25 takes its layouts as the file is read, then becomes today's page")
    func migratesAnOlderDefault() {
        let url = savedHome(HomeDefaultsRhythmMigration.previousDefaults(for: chinese))
        let store = HomePageStore(fileURL: url, defaults: suite(), appliesDefaultsRhythmOnce: true)
        #expect(page(store, chinese).sections.map(\.binding) == HomePageDefaults.page(for: chinese).sections.map(\.binding))
    }

    @Test("the page is made for the reader as the home knows them now: their mode and languages")
    func madeForTheReaderNow() {
        let url = savedHome(Migration.previousDefaults(for: chinese))
        let store = HomePageStore(fileURL: url, defaults: suite(), appliesDefaultsRhythmOnce: true)
        let now = context(["en"], mode: .bookSources)
        #expect(page(store, now).sections.map(\.binding) == HomePageDefaults.page(for: now).sections.map(\.binding))
        #expect(store.home?.defaultsLanguages == ["en"])
    }

    @Test("a 預設 the reader changed keeps its sections, and is not looked at again")
    func changedKept() throws {
        var saved = Migration.previousDefaults(for: chinese)
        saved[try position(of: popular, in: saved)].isEnabled = false
        let url = savedHome(saved)
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(page(store, chinese).sections == saved)
        #expect(defaults.bool(forKey: HomePageStore.defaultsStoreKey))
    }

    @Test("預設 only: a 首頁配置 of the reader's own holding the old defaults keeps them, and stays selected")
    func ownConfigurationsKept() {
        let old = Migration.previousDefaults(for: chinese)
        let url = savedHome(old)
        let maker = HomePageStore(fileURL: url)
        maker.createConfiguration(named: "我的", from: .blank, defaults: chinese)
        maker.save(HomePage(sections: Migration.previousDefaults(for: chinese)))
        maker.waitForPendingWritesForTesting()
        let own = maker.selectedConfiguration

        let store = HomePageStore(fileURL: url, defaults: suite(), appliesDefaultsRhythmOnce: true)
        #expect(page(store, chinese).sections.map(\.binding) == old.map(\.binding))
        #expect(store.selectedConfiguration == own)
        #expect(store.home?.sections(of: .defaults).map(\.binding) == HomePageDefaults.page(for: chinese).sections.map(\.binding))
    }

    @Test("a new install is made as today's page and never looked at; a store that is not the app's own changes nothing")
    func newInstallAndOtherStores() {
        let defaults = suite()
        let fresh = HomePageStore(fileURL: scratch(), defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(page(fresh, chinese).sections.map(\.binding) == HomePageDefaults.page(for: chinese).sections.map(\.binding))
        #expect(defaults.bool(forKey: HomePageStore.defaultsStoreKey))

        let old = Migration.previousDefaults(for: chinese)
        let other = suite()
        let plain = HomePageStore(fileURL: savedHome(old), defaults: other)
        #expect(page(plain, chinese).sections == old)
        #expect(!other.bool(forKey: HomePageStore.defaultsStoreKey))
    }
}
