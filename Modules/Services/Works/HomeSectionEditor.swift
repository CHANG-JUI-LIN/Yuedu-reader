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
        var binding: HomeSectionBinding?
        var isEnabled: Bool
        var parameters: [String: String]

        var section: HomeSection? {
            binding.map { HomeSection(id: id, layout: layout, title: title, binding: $0, isEnabled: isEnabled, parameters: parameters) }
        }
    }

    @Published private(set) var draft: Draft
    /// 新增欄目's form, not yet on the home.
    let isNew: Bool
    let preview: HomeModel
    private let store: HomePageStore
    /// The title the last choice gave, which the next one may replace.
    private var chosenTitle = ""

    /// 新增欄目: `layout` chosen first (Rex's order, decision 23).
    init(newSectionIn store: HomePageStore? = nil, layout: HomeSectionLayout, preview: HomeModel) {
        draft = Draft(id: UUID(), layout: layout, title: "", binding: nil, isEnabled: true, parameters: [:])
        isNew = true
        self.store = store ?? .shared
        self.preview = preview
    }

    init(section: HomeSection, store: HomePageStore? = nil, preview: HomeModel) {
        draft = Draft(id: section.id, layout: section.layout, title: section.title, binding: section.binding,
                      isEnabled: section.isEnabled, parameters: section.parameters)
        isNew = false
        self.store = store ?? .shared
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
        }
        if followsChoice { chosenTitle = title }
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

    /// 新增: the section at the end of the selected 首頁配置. False when it has no binding yet.
    @discardableResult
    func add() -> Bool {
        guard isNew, let section = draft.section else { return false }
        store.edit { $0.appendSection(section) }
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
