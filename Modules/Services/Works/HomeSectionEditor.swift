import Combine
import Foundation

/// Unified library 5d-5: one section's form, for 新增欄目 and for a section already on the home
/// (design §13.3, Rex's 「設定資料來源」; Phase 5 plan, decision 23).
///
/// - 新增欄目 keeps its section here until 新增: a form left with 取消 changes nothing. Its
///   section has no binding until 選擇內容來源 gives it one.
/// - A section already on the home is written back on every change, as the rest of 編輯首頁
///   writes (`HomePageStore.edit`), in its place.
/// - The preview is a home of its own (`preview`) with the one section, so it loads one real
///   page of it as the home would, without touching the home's rows.
@MainActor
final class HomeSectionEditor: ObservableObject {
    /// The section as the form shows it.
    struct Draft: Equatable {
        var id: UUID
        var layout: HomeSectionLayout
        /// Empty reads the binding's own.
        var title: String
        /// Empty reads the binding's own, if it has one.
        var subtitle: String
        var binding: HomeSectionBinding?
        var isEnabled: Bool
        var parameters: [String: String]

        var section: HomeSection? {
            binding.map {
                HomeSection(id: id, layout: layout, title: title, subtitle: subtitle, binding: $0, isEnabled: isEnabled,
                            parameters: parameters)
            }
        }
    }

    @Published private(set) var draft: Draft
    /// 新增欄目's form, not yet on the home.
    let isNew: Bool
    let preview: HomeModel
    private let store: HomePageStore
    private let aggregation: AggregationSettingsStore
    /// 新增欄目's 顯示在最新 choices, written on 新增 (`isNew` only).
    @Published private var pendingLatest: [SourceInstanceKey: Bool] = [:]
    /// The title the last choice gave, which the next one may replace.
    private var chosenTitle = ""

    /// 新增欄目: `layout` chosen first (Rex's order, decision 23).
    init(newSectionIn store: HomePageStore? = nil, layout: HomeSectionLayout,
         aggregation: AggregationSettingsStore? = nil, preview: HomeModel) {
        draft = Draft(id: UUID(), layout: layout, title: "", subtitle: "", binding: nil, isEnabled: true, parameters: [:])
        isNew = true
        self.store = store ?? .shared
        self.aggregation = aggregation ?? .shared
        self.preview = preview
    }

    init(section: HomeSection, store: HomePageStore? = nil, aggregation: AggregationSettingsStore? = nil,
         preview: HomeModel) {
        draft = Draft(id: section.id, layout: section.layout, title: section.title, subtitle: section.subtitle,
                      binding: section.binding, isEnabled: section.isEnabled, parameters: section.parameters)
        isNew = false
        self.store = store ?? .shared
        self.aggregation = aggregation ?? .shared
        self.preview = preview
    }

    /// What the preview draws: the section, shown, whatever 在首頁顯示 says.
    var previewPage: HomePage? {
        guard var section = draft.section else { return nil }
        section.isEnabled = true
        return HomePage(sections: [section])
    }

    // MARK: Changing

    func setLayout(_ layout: HomeSectionLayout) {
        change { $0.layout = layout }
    }

    func setTitle(_ title: String) {
        change { $0.title = title }
    }

    func setSubtitle(_ subtitle: String) {
        change { $0.subtitle = subtitle }
    }

    func setEnabled(_ isEnabled: Bool) {
        change { $0.isEnabled = isEnabled }
    }

    /// 選擇內容來源's choice, with the parameters that go with it; those of the binding it
    /// replaces go.
    /// - Parameter itemTitle: the choice's name, for a binding that cannot name itself (a
    ///   feed): it becomes the title (design §13.3: 「預設帶入子項目名稱」), unless the reader
    ///   gave one. A binding that names itself leaves the title empty, to follow it.
    func choose(_ binding: HomeSectionBinding, parameters: [String: String] = [:], itemTitle: String = "") {
        let ownName = HomeSection(layout: draft.layout, binding: binding).displayTitle(sourceName: "")
        let followsChoice = draft.title.isEmpty || draft.title == chosenTitle
        let title = ownName.isEmpty ? itemTitle : ""
        change {
            $0.binding = binding
            $0.parameters = parameters
            if followsChoice { $0.title = title }
            // What is lists alone is drawn only by the layouts of lists (`HomeLayoutStyle.choices`).
            if !HomeLayoutStyle.choices(for: binding).contains($0.layout.style) { $0.layout = .collection }
        }
        if followsChoice { chosenTitle = title }
    }

    /// A module list's parameter (Phase 6f), by its name; nil goes back to the module's default.
    func setParameter(_ name: String, to value: String?) {
        change { $0.parameters[name] = value }
    }

    // MARK: 最新's categories

    /// The categories picked for 最新, one per book source (design §13.3: a book source's 最新 is
    /// the discover category the reader picks for it), by source URL.
    var latestCategories: [ExploreCategoryReference] {
        guard let section = draft.section, section.binding == .latest else { return [] }
        let prefix = HomeSection.latestCategoryKey(sourceURL: "")
        return section.parameters.keys.filter { $0.hasPrefix(prefix) }.sorted()
            .compactMap { section.latestCategory(forSourceURL: String($0.dropFirst(prefix.count))) }
    }

    /// Picks the category that stands for a book source in 最新, with the discover filter values
    /// it was picked under; nil takes the source out of it.
    func setLatestCategory(_ reference: ExploreCategoryReference?, filterValues: [String: String] = [:],
                           forSourceURL sourceURL: String) {
        guard var section = draft.section, section.binding == .latest else { return }
        section.setLatestCategory(reference, forSourceURL: sourceURL)
        if reference != nil { section.setFilterValues(filterValues, forSourceURL: sourceURL) }
        change { $0.parameters = section.parameters }
    }

    /// The discover filter values the section's category of `sourceURL` was picked under
    /// (`HomeSection.filtersKey`).
    func filterValues(forSourceURL sourceURL: String) -> [String: String] {
        HomeSection.filterValues(in: draft.parameters, sourceURL: sourceURL)
    }

    // MARK: A section of lists

    /// The cards the section draws in a layout of lists (`HomeSection.listCards`), in this order.
    var listCards: [HomeListCard] {
        draft.section?.listCards ?? []
    }

    var canAddCard: Bool {
        listCards.count < HomeSection.listCardLimit
    }

    /// 加入清單: `cards` after the ones there, each once, up to `HomeSection.listCardLimit`.
    func addCards(_ cards: [HomeListCard]) {
        var kept = listCards
        for card in cards where kept.count < HomeSection.listCardLimit && !kept.contains(card) { kept.append(card) }
        setCards(kept)
    }

    /// The last card stays: without it the section would show nothing.
    func removeCard(at index: Int) {
        var cards = listCards
        guard cards.count > 1, cards.indices.contains(index) else { return }
        cards.remove(at: index)
        setCards(cards)
    }

    /// Moves cards as `List.onMove` reports it.
    func moveCards(fromOffsets source: IndexSet, toOffset destination: Int) {
        var cards = listCards
        guard source.allSatisfy(cards.indices.contains), (0...cards.count).contains(destination) else { return }
        let moving = source.sorted().map { cards[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) { cards.remove(at: offset) }
        cards.insert(contentsOf: moving, at: insertion)
        setCards(cards)
    }

    /// A card's own parameter (趨勢's 地區, maintainer 2026-10-27); nil goes back to its list's default.
    func setCardParameter(at index: Int, _ name: String, to value: String?) {
        var cards = listCards
        guard cards.indices.contains(index) else { return }
        cards[index].parameters[name] = value
        moveCardPhoto(from: listCards[index], to: cards[index])
        setCards(cards)
    }

    /// A card's list picked again: a category under other filters.
    func replaceCard(at index: Int, with card: HomeListCard) {
        var cards = listCards
        guard cards.indices.contains(index), !cards.contains(card) else { return }
        cards[index] = card
        moveCardPhoto(from: listCards[index], to: card)
        setCards(cards)
    }

    /// 大圖卡片's photos, the home's.
    var cardPhotos: HomeListCardPhotos { store.cardPhotos }

    /// The photo `card` has in this section (`HomeListCardPhotoID`).
    func photoID(of card: HomeListCard) -> HomeListCardPhotoID? {
        HomeListCardPhotoID(section: draft.id, binding: card.binding, parameters: card.parameters)
    }

    /// A card named anew keeps its photo. One removed loses it when the store next reads the
    /// home (`HomePageStore.init`).
    private func moveCardPhoto(from old: HomeListCard, to new: HomeListCard) {
        guard let from = photoID(of: old), let to = photoID(of: new) else { return }
        store.cardPhotos.movePhoto(from: from, to: to)
    }

    /// The cards written as the section (`HomeSection.settingCards`), and after them those the
    /// form does not show, kept as they were: a later build's lists, and any past the limit. One
    /// card of a list that cannot name itself titles the section as 選擇內容來源's choice does;
    /// more cards take that title back, so the section follows its source.
    private func setCards(_ cards: [HomeListCard]) {
        guard !cards.isEmpty else { return }
        var kept = cards
        if case .lists(let stored) = draft.binding {
            kept += stored.filter(\.isDrawable).dropFirst(HomeSection.listCardLimit) + stored.filter { !$0.isDrawable }
        }
        let base = HomeSection(id: draft.id, layout: draft.layout, title: draft.title, subtitle: draft.subtitle,
                               binding: draft.binding ?? .lists([]), isEnabled: draft.isEnabled, parameters: draft.parameters)
        let written = base.settingCards(kept)
        let followsChoice = draft.title.isEmpty || draft.title == chosenTitle
        let title = cards.count == 1 ? cards[0].title : ""
        change {
            $0.binding = written.binding
            $0.parameters = written.parameters
            if followsChoice { $0.title = title }
        }
        if followsChoice { chosenTitle = title }
    }

    // MARK: 最新's libraries

    /// 顯示在最新, set in 最新's form as Emby 4.10 sets a section's libraries (decision 36). It
    /// stays 聚合設定's one value (`AggregationSettingsStore.hiddenFromLatest`), which every 最新
    /// section shares; 新增欄目 keeps the reader's choice until 新增.
    func isShownInLatest(_ key: SourceInstanceKey) -> Bool {
        pendingLatest[key] ?? aggregation.isShownInLatest(key)
    }

    func setShownInLatest(_ shown: Bool, for key: SourceInstanceKey) {
        if isNew { pendingLatest[key] = shown } else { aggregation.setShownInLatest(shown, for: key) }
    }

    /// The libraries 最新 leaves out, with the form's choices: what the preview loads without.
    var hiddenFromLatest: Set<SourceInstanceKey> {
        var hidden = Set(aggregation.settings.hiddenFromLatest ?? [])
        for (key, shown) in pendingLatest {
            if shown { hidden.remove(key) } else { hidden.insert(key) }
        }
        return hidden
    }

    /// 新增: the section at the end of the selected 首頁配置, and, for 最新, its libraries' choices.
    /// False when it has no binding yet.
    @discardableResult
    func add() -> Bool {
        guard isNew, let section = draft.section else { return false }
        store.edit { $0.appendSection(section) }
        if section.binding == .latest {
            for (key, shown) in pendingLatest.sorted(by: { $0.key.id < $1.key.id }) {
                aggregation.setShownInLatest(shown, for: key)
            }
        }
        return true
    }

    func delete() {
        guard !isNew else { return }
        store.edit { $0.removeSection(draft.id) }
    }

    private func change(_ apply: (inout Draft) -> Void) {
        var changed = draft
        apply(&changed)
        guard changed != draft else { return }
        draft = changed
        guard !isNew, let section = changed.section else { return }
        store.edit { $0.replaceSection(section) }
    }
}
