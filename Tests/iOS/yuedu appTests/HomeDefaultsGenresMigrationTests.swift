import Foundation
import Testing
@testable import yuedu_app

// The 2026-11-15 page with its genres, for a 預設 still as the 2026-11-14 page made it (maintainer,
// 2026-11-15): that page becomes today's, whole, once, under a key of its own, since installs that
// ran 2026-11-14's build have spent `defaultsStoreKey` already; any other 預設 is the reader's.

private typealias Migration = HomeDefaultsGenresMigration

private func genresContext(_ languages: [String], mode: ExploreMode = .publicLibraries,
                           libraries: Bool = true) -> HomePageDefaults.Context {
    HomePageDefaults.Context(mode: mode, publicLibrariesAvailable: libraries, languages: languages)
}

@Suite("Home defaults genres migration")
struct HomeDefaultsGenresMigrationTests {
    @Test("the untouched 2026-11-14 page is recognised, whomever it was made for; today's page is not")
    func untouched() {
        for context in HomeDefaultsRhythmMigration.contexts {
            #expect(Migration.recognises(Migration.storeDefaults(for: context)))
            #expect(!Migration.recognises(HomePageDefaults.page(for: context).sections))
        }
    }

    @Test("a 2026-11-14 page the reader changed is theirs: a section hidden, titled, removed or moved")
    func changed() {
        let made = Migration.storeDefaults(for: genresContext(["zh"]))
        var hidden = made
        hidden[2].isEnabled = false
        var titled = made
        titled[3].title = "我的"
        var removed = made
        removed.remove(at: 4)
        var moved = made
        moved.swapAt(2, 3)
        for sections in [hidden, titled, removed, moved] { #expect(!Migration.recognises(sections)) }
    }

    @Test("the frozen page is 2026-11-14's: 熱門精選 of 今年熱門, 完結推薦 and 經典名著, no genre")
    func frozen() {
        let made = Migration.storeDefaults(for: genresContext(["zh"]))
        #expect(made.contains { $0.binding == .lists(Migration.storePickCards) })
        #expect(!made.contains { $0.binding == .lists(HomePageDefaults.genreCards) || $0.binding == .readBefore })
    }
}

@Suite("Home defaults genres migration in the page store", .serialized)
@MainActor
struct HomeDefaultsGenresMigrationStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HomeDefaultsGenres-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("explore_home.json")
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "HomeDefaultsGenres-\(UUID().uuidString)")!
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

    private var chinese: HomePageDefaults.Context { genresContext(["zh"]) }

    @Test("an untouched 2026-11-14 page becomes today's once, on an install whose 2026-11-14 key is spent")
    func migratesOnce() {
        let url = savedHome(Migration.storeDefaults(for: chinese))
        let defaults = suite()
        defaults.set(true, forKey: HomePageStore.defaultsRhythmKey)
        defaults.set(true, forKey: HomePageStore.defaultsStoreKey)
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        let today = HomePageDefaults.page(for: chinese).sections
        let shown = page(store, chinese)
        #expect(shown.sections.map(\.binding) == today.map(\.binding))
        #expect(shown.sections.map(\.layout) == today.map(\.layout))
        #expect(defaults.bool(forKey: HomePageStore.defaultsGenresKey))
        store.waitForPendingWritesForTesting()

        // The reader takes 之前讀過 off: theirs from now on.
        store.edit { $0.sections.removeAll { $0.binding == .readBefore } }
        store.waitForPendingWritesForTesting()
        let again = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(!page(again, chinese).sections.contains { $0.binding == .readBefore })
    }

    @Test("a 預設 older than 2026-11-14 reaches today's page in one read")
    func olderInOneRead() {
        let url = savedHome(HomeDefaultsStoreMigration.previousDefaults(for: chinese))
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(page(store, chinese).sections.map(\.binding) == HomePageDefaults.page(for: chinese).sections.map(\.binding))
        #expect(defaults.bool(forKey: HomePageStore.defaultsStoreKey) && defaults.bool(forKey: HomePageStore.defaultsGenresKey))
    }

    @Test("a 2026-11-14 page the reader changed keeps its sections")
    func changedKept() {
        var saved = Migration.storeDefaults(for: chinese)
        saved[2].isEnabled = false
        let url = savedHome(saved)
        let defaults = suite()
        defaults.set(true, forKey: HomePageStore.defaultsStoreKey)
        let store = HomePageStore(fileURL: url, defaults: defaults, appliesDefaultsRhythmOnce: true)
        #expect(page(store, chinese).sections == saved)
        #expect(defaults.bool(forKey: HomePageStore.defaultsGenresKey))
    }
}
