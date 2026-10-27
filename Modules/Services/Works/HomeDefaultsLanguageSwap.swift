import Foundation

/// 預設 follows 中繼資料語言偏好推薦 (maintainer, 2026-10-27: a changed language left 預設 with the
/// last language's lists until they made a 首頁配置 from 預設配置). The official modules' lists the
/// defaults give one language (`HomePageDefaults.officialModuleLists`) give way to the next
/// language's; nothing else on 預設 changes.
///
/// - A list goes while it is as some defaults made it: a layout the defaults gave it (today's,
///   the band, or that of 2026-10-13 to 2026-10-25), no title, subtitle or parameters, shown. The
///   band, the 頂部輪播圖, goes hidden too, and the band that comes in is hidden as it was:
///   關閉輪播圖 is the reader's choice for the 輪播圖, not for the list on it.
/// - A list the reader changed or hid stays, as does every other section, a 輪播圖 they chose
///   (選擇輪播數據) among them.
/// - The new language's lists go where the first that went was. When none went, they go where
///   the defaults put them, unless the reader took every one of the last language's lists off:
///   then there is nothing they replace. One the page has already is not added again.
/// - The first list that comes in with covers takes the band, unless a band stays. なろう has
///   none, so Japanese has no 輪播圖, as its defaults have none.
///
/// `HomePageStore` runs it on 預設 only, when the language is not the one 預設's lists are for
/// (`HomeConfigurations.defaultsLanguages`): the reader's own 首頁配置 are theirs.
enum HomeDefaultsLanguageSwap {
    struct Outcome: Equatable {
        var sections: [HomeSection]
        /// The last language's lists taken away.
        var removed: Int
        /// The new language's lists put in.
        var added: Int
    }

    /// - Parameters:
    ///   - languages: whose lists `sections` hold, base codes.
    ///   - context: the defaults now: the language, and the mode and region they place lists for.
    static func apply(to sections: [HomeSection], from languages: [String], to context: HomePageDefaults.Context,
                      makeID: () -> UUID = UUID.init) -> Outcome {
        let available = context.publicLibrariesAvailable
        let staying = Set(HomePageDefaults.officialModuleLists(languages: context.languages, publicLibrariesAvailable: available)
            .map(\.binding))
        let made = madeLayouts(languages: languages, context: context)

        var kept: [HomeSection] = []
        var firstGone: Int?
        var goneBand: HomeSection?
        for section in sections {
            let asMade = made[section.binding]?.contains(section.layout) == true && section.title.isEmpty
                && section.subtitle.isEmpty && section.parameters.isEmpty && (section.isEnabled || section.layout == .band)
            guard asMade, !staying.contains(section.binding) else {
                kept.append(section)
                continue
            }
            if firstGone == nil { firstGone = kept.count }
            if section.layout == .band, goneBand == nil { goneBand = section }
        }

        // The last language had lists, and the reader took them all off.
        guard firstGone != nil || made.isEmpty || kept.contains(where: { made[$0.binding] != nil }) else {
            return Outcome(sections: sections, removed: 0, added: 0)
        }
        let present = Set(kept.map(\.binding))
        let bandStays = kept.contains { $0.layout == .band && $0.isEditable }
        let incoming = HomePageDefaults.officialModuleLists(
            languages: context.languages, publicLibrariesAvailable: available,
            takesBand: { !bandStays && !present.contains($0.binding) && made[$0.binding] == nil })
            .filter { !present.contains($0.binding) && made[$0.binding] == nil }
            .map { list in
                HomeSection(id: makeID(), layout: list.layout, binding: list.binding,
                            isEnabled: list.layout == .band ? goneBand?.isEnabled ?? true : true)
            }
        var swapped = kept
        swapped.insert(contentsOf: incoming, at: firstGone ?? defaultsPlace(in: kept, context: context))
        return Outcome(sections: swapped, removed: sections.count - kept.count, added: incoming.count)
    }

    /// Whose lists a 預設 saved before 2026-10-27 holds, which it did not say: each language with
    /// lists that it has any of, in the order its sections have them.
    static func languages(of sections: [HomeSection], publicLibrariesAvailable: Bool) -> [String] {
        let lists = HomePageDefaults.listLanguages.map { language in
            (language, Set(HomePageDefaults.officialModuleLists(languages: [language], publicLibrariesAvailable: publicLibrariesAvailable)
                .map(\.binding)))
        }
        var found: [String] = []
        for section in sections {
            for (language, bindings) in lists where !found.contains(language) && bindings.contains(section.binding) {
                found.append(language)
            }
        }
        return found
    }

    /// The layouts the defaults have given each of `languages`' lists: its own, the band, and
    /// that of 2026-10-13 to 2026-10-25 (`HomeDefaultsRhythmMigration` left a 預設 it did not
    /// recognise with them).
    private static func madeLayouts(languages: [String],
                                    context: HomePageDefaults.Context) -> [HomeSectionBinding: Set<HomeSectionLayout>] {
        var layouts: [HomeSectionBinding: Set<HomeSectionLayout>] = [:]
        let lists = HomePageDefaults.officialModuleLists(languages: languages, publicLibrariesAvailable: context.publicLibrariesAvailable,
                                                         takesBand: { _ in false })
        for list in lists { layouts[list.binding] = [list.layout, .band] }
        let before = HomeDefaultsRhythmMigration.previousDefaults(
            for: HomePageDefaults.Context(mode: context.mode, publicLibrariesAvailable: context.publicLibrariesAvailable,
                                          languages: languages))
        for section in before where layouts[section.binding] != nil { layouts[section.binding]?.insert(section.layout) }
        return layouts
    }

    /// Where the defaults put the lists: after the sections they put before them (繼續閱讀 and
    /// 系列下一本, and 最新 where 來源配置 come first), else first.
    private static func defaultsPlace(in sections: [HomeSection], context: HomePageDefaults.Context) -> Int {
        let before = Set(HomePageDefaults.page(for: context).sections
            .prefix { if case .module = $0.binding { false } else { true } }
            .map(\.binding))
        return sections.lastIndex { before.contains($0.binding) }.map { $0 + 1 } ?? 0
    }
}
