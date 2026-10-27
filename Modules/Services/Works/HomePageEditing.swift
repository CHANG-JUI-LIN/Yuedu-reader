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
    /// layout change only how it is drawn, except that a layout of lists loads lists where a
    /// layout of books loads books (the 書架's groups, `HomeSection.listCards`).
    func loadsSameContent(as other: HomeSection) -> Bool {
        parameters == other.parameters && binding == other.binding && drawsLists == other.drawsLists
    }
}

extension HomePage {
    /// The sections 編輯首頁 lists, in the page's order: not the 頂部輪播圖, which its header sets.
    var editableSections: [HomeSection] {
        let carousel = carouselSection?.id
        return sections.filter { $0.isEditable && $0.id != carousel }
    }

    /// Moves listed sections as `List.onMove` reports it, in `editableSections`' offsets.
    mutating func moveEditable(fromOffsets source: IndexSet, toOffset destination: Int) {
        let carousel = carouselSection?.id
        let places = sections.indices.filter { sections[$0].isEditable && sections[$0].id != carousel }
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

// The maintainer, 2026-10-27: 色帶書架 at the top of the home, as an Emby client's 輪播圖, set
// from 編輯首頁's header (選擇輪播數據, 關閉輪播圖) as that client's editor sets it. The page's
// first band is the 輪播圖, shown or hidden; where it stands among the sections changes nothing.
// The defaults and their 2026-10-25 migration already give the band to the list it belongs on.
extension HomePage {
    /// The 頂部輪播圖: the first band, drawn at the top while it is enabled.
    var carouselSection: HomeSection? {
        sections.first { $0.layout == .band && $0.isEditable }
    }

    /// 選擇輪播數據: the 輪播圖 shows `binding`, under that binding's own name. A page without one
    /// gets one, shown, before its first section.
    mutating func setCarousel(_ binding: HomeSectionBinding, parameters: [String: String] = [:], title: String = "") {
        if let index = sections.firstIndex(where: { $0.id == carouselSection?.id }) {
            sections[index].binding = binding
            sections[index].parameters = parameters
            sections[index].title = title
            sections[index].subtitle = ""
            sections[index].isEnabled = true
        } else {
            sections.insert(HomeSection(layout: .band, title: title, binding: binding, parameters: parameters), at: 0)
        }
    }

    /// 關閉輪播圖 and 開啟輪播圖: the 輪播圖 keeps what it shows while it is hidden.
    mutating func setCarouselShown(_ isShown: Bool) {
        guard let id = carouselSection?.id else { return }
        setEnabled(isShown, section: id)
    }
}
