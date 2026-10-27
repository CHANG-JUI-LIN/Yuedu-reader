import Foundation
import Testing
@testable import yuedu_app

// 預設 follows the language (maintainer, 2026-10-27): the last language's official modules' lists,
// as the defaults made them, give way to the new language's in their place; what the reader
// changed stays, and their own 首頁配置 are not touched.

private typealias Swap = HomeDefaultsLanguageSwap

private func context(_ languages: [String], mode: ExploreMode = .publicLibraries,
                     libraries: Bool = true) -> HomePageDefaults.Context {
    HomePageDefaults.Context(mode: mode, publicLibrariesAvailable: libraries, languages: languages)
}

private func defaults(_ languages: [String], mode: ExploreMode = .publicLibraries, libraries: Bool = true) -> [HomeSection] {
    HomePageDefaults.page(for: context(languages, mode: mode, libraries: libraries)).sections
}

private func position(of binding: HomeSectionBinding, in sections: [HomeSection]) throws -> Int {
    try #require(sections.firstIndex { $0.binding == binding })
}

private let bangumiNovels = HomeSectionBinding.module(moduleID: "bangumi", entryID: "novel-rank")
private let bangumiManga = HomeSectionBinding.module(moduleID: "bangumi", entryID: "manga-rank")
private let anilistNovels = HomeSectionBinding.module(moduleID: "anilist", entryID: "trending-novels")
private let anilistManga = HomeSectionBinding.module(moduleID: "anilist", entryID: "trending-manga")

@Suite("Home defaults follow the language")
struct HomeDefaultsLanguageSwapTests {
    @Test("an untouched 預設 becomes the new language's defaults, its other sections kept, ids and all")
    func untouched() {
        let languages = ["zh", "ja", "en", "ko"]
        for mode in ExploreMode.allCases {
            for libraries in [true, false] {
                for from in languages {
                    for to in languages where to != from {
                        let saved = defaults([from], mode: mode, libraries: libraries)
                        let outcome = Swap.apply(to: saved, from: [from], to: context([to], mode: mode, libraries: libraries))
                        let wanted = defaults([to], mode: mode, libraries: libraries)
                        let label = "\(from)→\(to) \(mode) libraries: \(libraries)"
                        #expect(outcome.sections.map(\.binding) == wanted.map(\.binding), "\(label)")
                        #expect(outcome.sections.map(\.layout) == wanted.map(\.layout), "\(label)")
                        let others = saved.filter { if case .module = $0.binding { false } else { true } }
                        #expect(outcome.sections.filter { others.map(\.id).contains($0.id) } == others, "\(label)")
                    }
                }
            }
        }
    }

    @Test("中文 to English: AniList takes Bangumi's place and the 輪播圖")
    func chineseToEnglish() throws {
        let saved = defaults(["zh"])
        let outcome = Swap.apply(to: saved, from: ["zh"], to: context(["en"]))
        let place = try position(of: bangumiNovels, in: saved)
        #expect(outcome.sections[place].binding == anilistNovels)
        #expect(HomePage(sections: outcome.sections).carouselSection?.binding == anilistNovels)
        #expect(outcome.removed == 2)
        #expect(outcome.added == 2)
    }

    @Test("日本語 has no 輪播圖: なろう has no covers")
    func japaneseHasNoBand() {
        let outcome = Swap.apply(to: defaults(["zh"]), from: ["zh"], to: context(["ja"]))
        #expect(!outcome.sections.contains { $0.layout == .band })
        #expect(outcome.sections.contains { $0.binding == .module(moduleID: "narou", entryID: "weekly") })
    }

    @Test("the same language, in another script, changes nothing")
    func sameLanguage() {
        let saved = defaults(["zh"])
        #expect(Swap.apply(to: saved, from: ["zh"], to: context(["zh"])) == .init(sections: saved, removed: 0, added: 0))
    }

    @Test("a list the reader titled, gave a subtitle or parameters, drew another way or hid stays where it is")
    func editedListKept() throws {
        let edits: [(name: String, edit: (inout HomeSection) -> Void)] = [
            ("titled", { $0.title = "動畫排行" }),
            ("subtitled", { $0.subtitle = "本週" }),
            ("parameters", { $0.parameters = ["sort": "week"] }),
            ("another layout", { $0.layout = .coverGrid }),
            ("hidden", { $0.isEnabled = false }),
        ]
        for (name, edit) in edits {
            var saved = defaults(["zh"])
            let manga = try position(of: bangumiManga, in: saved)
            edit(&saved[manga])
            let outcome = Swap.apply(to: saved, from: ["zh"], to: context(["en"]))
            #expect(outcome.sections.contains(saved[manga]), "\(name)")
            #expect(!outcome.sections.contains { $0.binding == bangumiNovels }, "\(name)")
            #expect(outcome.sections.contains { $0.binding == anilistNovels } && outcome.sections.contains { $0.binding == anilistManga },
                    "\(name)")
            #expect(outcome.removed == 1, "\(name)")
        }
    }

    @Test("a 輪播圖 the reader chose stays, and AniList's novels come in as a row")
    func chosenCarouselKept() {
        var page = HomePage(sections: defaults(["zh"]))
        page.setCarousel(.gutenbergCollection(id: "children"))
        let outcome = Swap.apply(to: page.sections, from: ["zh"], to: context(["en"]))
        let swapped = HomePage(sections: outcome.sections)
        #expect(swapped.carouselSection == page.carouselSection)
        #expect(outcome.sections.filter { $0.layout == .band }.count == 1)
        #expect(outcome.sections.first { $0.binding == anilistNovels }?.layout == .row)
        #expect(!outcome.sections.contains { $0.binding == bangumiManga })
    }

    @Test("關閉輪播圖 holds for the new 輪播圖; a language without one shows its lists")
    func hiddenCarousel() {
        var page = HomePage(sections: defaults(["zh"]))
        page.setCarouselShown(false)
        let english = HomePage(sections: Swap.apply(to: page.sections, from: ["zh"], to: context(["en"])).sections)
        #expect(english.carouselSection?.binding == anilistNovels)
        #expect(english.carouselSection?.isEnabled == false)
        #expect(!english.sections.contains { $0.binding == bangumiNovels })

        let japanese = Swap.apply(to: page.sections, from: ["zh"], to: context(["ja"])).sections
        #expect(!japanese.contains { $0.layout == .band })
        #expect(japanese.first { $0.binding == .module(moduleID: "narou", entryID: "weekly") }?.isEnabled == true)
    }

    @Test("a 預設 the reader took every list off gets none; one with a list already keeps it once")
    func removedListsStayOff() {
        let emptied = defaults(["zh"]).filter { if case .module = $0.binding { false } else { true } }
        #expect(Swap.apply(to: emptied, from: ["zh"], to: context(["en"])) == .init(sections: emptied, removed: 0, added: 0))

        var added = defaults(["zh"])
        added.append(HomeSection(layout: .row, title: "我的", binding: anilistManga))
        let outcome = Swap.apply(to: added, from: ["zh"], to: context(["en"]))
        #expect(outcome.sections.filter { $0.binding == anilistManga }.count == 1)
        #expect(outcome.sections.last?.title == "我的")
    }

    @Test("a language without lists to one with them: where the defaults put them")
    func fromNoLists() throws {
        let saved = defaults(["ko"], mode: .bookSources)
        let outcome = Swap.apply(to: saved, from: ["ko"], to: context(["en"], mode: .bookSources))
        let latest = try position(of: .latest, in: outcome.sections)
        #expect(outcome.sections[latest + 1].binding == anilistNovels)
    }

    @Test("whose lists a 預設 from before the language was saved holds")
    func languagesHeld() {
        #expect(Swap.languages(of: defaults(["zh"]), publicLibrariesAvailable: true) == ["zh"])
        #expect(Swap.languages(of: defaults(["ko"]), publicLibrariesAvailable: true).isEmpty)
        let both = HomeDefaultsRhythmMigration.previousDefaults(for: context(["en", "zh"]))
        #expect(Swap.languages(of: both, publicLibrariesAvailable: true) == ["en", "zh"])
    }
}

@Suite("Home defaults follow the language in the store", .serialized)
@MainActor
struct HomeDefaultsLanguageStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HomeDefaultsLanguage-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("explore_home.json")
    }

    /// A file saved before 2026-10-27: 預設 alone, not saying whose lists it holds.
    private func savedHome(_ sections: [HomeSection]) -> URL {
        let url = scratch()
        let store = HomePageStore(fileURL: url)
        store.save(HomePage(sections: sections))
        store.waitForPendingWritesForTesting()
        return url
    }

    private func page(_ store: HomePageStore, _ languages: [String]) -> HomePage {
        store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true, languages: languages)
    }

    @Test("a new install's 預設 takes the next language's lists, and the file keeps them")
    func followsAndSaves() {
        let url = scratch()
        let store = HomePageStore(fileURL: url)
        let chinese = page(store, ["zh"])
        let english = page(store, ["en"])
        #expect(english.sections.map(\.binding) == defaults(["en"]).map(\.binding))
        #expect(english.sections.first?.id == chinese.sections.first?.id)
        #expect(page(store, ["en"]) == english, "once")
        store.waitForPendingWritesForTesting()

        let reopened = HomePageStore(fileURL: url)
        #expect(reopened.page == english)
        #expect(reopened.home?.defaultsLanguages == ["en"])
    }

    @Test("預設 only: the reader's own 首頁配置, selected, keeps the last language's lists")
    func ownConfigurationsKept() {
        let store = HomePageStore(fileURL: scratch())
        _ = page(store, ["zh"])
        store.createConfiguration(named: "週末", from: .defaults, defaults: context(["zh"]))
        let own = store.page
        #expect(page(store, ["en"]) == own)
        #expect(store.home?.sections(of: .defaults).map(\.binding) == defaults(["en"]).map(\.binding))
    }

    @Test("a 預設 saved before 2026-10-27 follows a language its lists are not for")
    func savedBeforeFollows() {
        let store = HomePageStore(fileURL: savedHome(defaults(["zh"])))
        #expect(page(store, ["en"]).sections.map(\.binding) == defaults(["en"]).map(\.binding))
        #expect(store.home?.defaultsLanguages == ["en"])
    }

    @Test("a 預設 saved before 2026-10-27 with the language's lists, or with none, is left as it is")
    func savedBeforeKept() {
        let chinese = defaults(["zh"])
        let same = HomePageStore(fileURL: savedHome(chinese))
        #expect(page(same, ["zh"]).sections == chinese)
        #expect(same.home?.defaultsLanguages == ["zh"])

        let none = defaults(["ko"])
        let emptied = HomePageStore(fileURL: savedHome(none))
        #expect(page(emptied, ["en"]).sections == none)
        #expect(emptied.home?.defaultsLanguages == ["en"])
    }

    @Test("a deleted 預設 stays deleted")
    func deletedDefaults() throws {
        let store = HomePageStore(fileURL: scratch())
        _ = page(store, ["zh"])
        store.createConfiguration(named: "週末", from: .blank, defaults: context(["zh"]))
        store.deleteConfiguration(.defaults)
        #expect(store.home?.defaultsDeleted == true)
        _ = page(store, ["en"])
        #expect(store.home?.sections.isEmpty == true)
    }
}
