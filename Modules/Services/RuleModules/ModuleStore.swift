import CryptoKit
import Foundation

// A module list's own store (`RuleModule.Entry.store`, format 3.0.2; maintainer, 2026-11-15:
// tapping a genre opens a small store, as Apple Books' 愛情 does): the list's sections, each
// the list with some of its values set, drawn as the home draws its sections.

/// A list that has a store: a row of 所有類型 and of a store's 類型.
struct ModuleStoreListing: Hashable, Identifiable, Sendable {
    let moduleID: String
    let entryID: String
    /// The list's name, in the app's language.
    let title: String

    var id: String { "\(moduleID)/\(entryID)" }
    var route: ModuleStoreRoute { ModuleStoreRoute(moduleID: moduleID, entryID: entryID, title: title) }
}

/// A list's store, pushed on 探索's stack; its name frozen for the bar while the module loads.
struct ModuleStoreRoute: Hashable, Sendable {
    let moduleID: String
    let entryID: String
    let title: String
}

enum ModuleStores {
    /// Every list with a store, module by module, each list in its file's order: the official
    /// store's first, novels before comics before Open Library's nonfiction (`storeOrder`), then
    /// the reader's in the library's order.
    static func listings(in modules: [RuleModule]) -> [ModuleStoreListing] {
        let rank = { (module: RuleModule) in OfficialRuleModules.storeOrder.firstIndex(of: module.id) ?? Int.max }
        let ordered = modules.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return ordered.flatMap { module in
            module.modules.compactMap { entry -> ModuleStoreListing? in
                guard let id = entry.id, !(entry.store ?? []).isEmpty,
                      let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
                return ModuleStoreListing(moduleID: module.id, entryID: id, title: title)
            }
        }
    }

    /// The installed modules' lists with a store, named in the app's language.
    @MainActor
    static func listings(in library: RuleModuleLibrary = .shared) -> [ModuleStoreListing] {
        listings(in: library.modules.map(\.module))
    }

    /// Whether a card of the list opens its store (`ExplorePlace.page(of:)`).
    @MainActor
    static func store(moduleID: String, entryID: String, in library: RuleModuleLibrary = .shared) -> ModuleStoreRoute? {
        guard let entry = library.module(id: moduleID)?.module.modules.first(where: { $0.id == entryID }),
              !(entry.store ?? []).isEmpty else { return nil }
        return ModuleStoreRoute(moduleID: moduleID, entryID: entryID, title: entry.title ?? "")
    }

    /// The store's sections, each named by the option it sets (本月熱門), in the app's language as
    /// the module is. The same ids every time, so a sync keeps what each row loaded. A section of
    /// shelves is 更多「愛情」, a shelf each list it names whose `belongTo` the store's own values,
    /// in `language` (地區 follows 中繼資料語言偏好推薦), take; none, and the section is left out.
    static func page(of entry: RuleModule.Entry, in module: RuleModule, language: String) -> HomePage {
        guard let entryID = entry.id else { return HomePage(sections: []) }
        let values = RuleModule.Param.currentValues(of: entry.params, in: [:], language: language)
        let sections = (entry.store ?? []).enumerated().compactMap { index, store -> HomeSection? in
            let id = sectionID(moduleID: module.id, entryID: entryID, index: index)
            if let shelves = store.shelves {
                let cards = shelves.compactMap { shelf -> HomeListCard? in
                    if let belongTo = shelf.belongTo, !belongTo.value.contains(values[belongTo.paramName] ?? "") { return nil }
                    let listID = shelf.list ?? entryID
                    guard let list = module.modules.first(where: { $0.id == listID }) else { return nil }
                    let parameters = shelf.params ?? [:]
                    return HomeListCard(binding: .module(moduleID: module.id, entryID: listID), parameters: parameters,
                                        title: shelf.list == nil ? title(of: parameters, in: list) : (list.title ?? listID))
                }
                guard !cards.isEmpty else { return nil }
                return HomeSection(id: id, layout: .groupedShelves,
                                   title: String(format: localized("書店：更多%@"), entry.title ?? ""), binding: .lists(cards))
            }
            let values = store.params ?? [:]
            return HomeSection(id: id, layout: HomeSectionLayout(rawValue: store.layout), title: title(of: values, in: entry),
                               binding: .module(moduleID: module.id, entryID: entryID), parameters: values)
        }
        return HomePage(sections: sections)
    }

    /// The title of the first option the section sets, in the entry's parameters' order; the
    /// list's own name when it sets none.
    static func title(of values: [String: String], in entry: RuleModule.Entry) -> String {
        for param in entry.params where param.kind == .enumeration {
            guard let value = values[param.name], let option = param.enumOptions?.first(where: { $0.value == value }) else { continue }
            return option.title
        }
        return entry.title ?? ""
    }

    private static func sectionID(moduleID: String, entryID: String, index: Int) -> UUID {
        let digest = Array(SHA256.hash(data: Data("store/\(moduleID)/\(entryID)/\(index)".utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}
