import Foundation

// Unified library 5d-2: 編輯首頁's edits (Phase 5 plan, 5d-2 and decision 14). The editor and a
// section name's long press change the page only through these, so both keep the same rules:
// - 編輯首頁 lists the sections a home draws. 我的書庫 (not drawn since 5d-1) and a later
//   build's sections are not listed; reordering moves the listed ones among the places they
//   held, so the others keep theirs.
// - A hidden section keeps its place and settings; a removed one is gone.

extension HomeSection {
    /// Whether 編輯首頁 lists it.
    var isEditable: Bool {
        binding.isKnown && binding != .myLibrary
    }
}

extension HomeSection {
    /// Whether a row of this section loads what a row of `other` loads: the title and the
    /// layout change only how it is drawn, except that a 來源配置's 分類卡片 loads a card per
    /// category where its other layouts load the first one's books.
    func loadsSameContent(as other: HomeSection) -> Bool {
        parameters == other.parameters && binding == other.binding && drawsCategoryCards == other.drawsCategoryCards
    }
}

extension HomePage {
    /// The sections 編輯首頁 lists, in the page's order.
    var editableSections: [HomeSection] {
        sections.filter(\.isEditable)
    }

    /// Moves listed sections as `List.onMove` reports it, in `editableSections`' offsets.
    mutating func moveEditable(fromOffsets source: IndexSet, toOffset destination: Int) {
        let places = sections.indices.filter { sections[$0].isEditable }
        var listed = places.map { sections[$0] }
        let moving = source.sorted().map { listed[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) { listed.remove(at: offset) }
        listed.insert(contentsOf: moving, at: insertion)
        for (place, section) in zip(places, listed) { sections[place] = section }
    }

    mutating func setEnabled(_ isEnabled: Bool, section id: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].isEnabled = isEnabled
    }

    /// 呈現方式 (5d-3).
    mutating func setLayout(_ layout: HomeSectionLayout, section id: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].layout = layout
    }

    mutating func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
    }
}

// Unified library 5d-5: the section form (Phase 5 plan, decision 23). 新增欄目 adds its section
// at the end; the form of a section already there writes it back in its place.
extension HomePage {
    mutating func appendSection(_ section: HomeSection) {
        sections.append(section)
    }

    /// The section of the same id, replaced; nothing when it is gone.
    mutating func replaceSection(_ section: HomeSection) {
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[index] = section
    }
}
