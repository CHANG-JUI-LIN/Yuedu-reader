import SwiftUI

// Search 9c: the one list of works in groups by kind, as Emby's search lists 人物, 電影 and
// 電視劇 under a header each, and the 類型 chip that narrows it to one.

extension ContentKind {
    /// The groups' order: 書籍, 漫畫, 有聲書.
    static let searchGroupOrder: [ContentKind] = [.text, .comic, .audio]

    /// A group's header, and the 類型 chip's choice.
    var searchGroupTitle: String {
        switch self {
        case .text: localized("搜尋分組：書籍")
        case .comic: localized("搜尋分組：漫畫")
        case .audio: localized("搜尋分組：有聲書")
        }
    }
}

/// One kind's works, in the resolver's order. The resolver merges only candidates of one
/// kind (`SearchWorkResolver`), so a work is in exactly one group.
struct UnifiedSearchGroup<Row>: Identifiable {
    let kind: ContentKind
    let rows: [Row]

    var id: ContentKind { kind }

    /// `rows` in groups: 書籍, 漫畫, 有聲書, those with nothing left out; with a `filter`, its
    /// kind's group alone.
    static func groups(of rows: [Row], kind: (Row) -> ContentKind, filter: ContentKind?) -> [Self] {
        var byKind: [ContentKind: [Row]] = [:]
        for row in rows { byKind[kind(row), default: []].append(row) }
        return ContentKind.searchGroupOrder.compactMap { groupKind in
            guard filter == nil || filter == groupKind, let rows = byKind[groupKind], !rows.isEmpty else { return nil }
            return UnifiedSearchGroup(kind: groupKind, rows: rows)
        }
    }
}

extension UnifiedSearchRow {
    var kind: ContentKind { work.lead.contentKind }
}

/// The 類型 chip: 全部, or one kind. A menu of one picker, so it opens no modal (no iOS 17
/// menu-to-sheet race); the choice lasts while the search page does.
struct SearchKindFilterChip: View {
    let model: UnifiedSearchModel

    private var title: String { model.kindFilter?.searchGroupTitle ?? localized("類型") }

    var body: some View {
        Menu {
            Picker(localized("類型"), selection: Binding(get: { model.kindFilter }, set: { model.kindFilter = $0 })) {
                Text(localized("全部")).tag(ContentKind?.none)
                ForEach(ContentKind.searchGroupOrder, id: \.self) { kind in
                    Text(kind.searchGroupTitle).tag(ContentKind?.some(kind))
                }
            }
        } label: {
            SearchFilterChipLabel(title: title)
        }
        .searchFilterChip(isActive: model.kindFilter != nil)
        .accessibilityLabel(localized("類型"))
        .accessibilityValue(model.kindFilter?.searchGroupTitle ?? localized("全部"))
        .accessibilityIdentifier("search.kindFilter")
        .searchFilterChipRowHeight()
    }
}

/// A chip's face, as Emby's: its title, then a chevron.
struct SearchFilterChipLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Text(title)
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .accessibilityHidden(true)
        }
        .font(DSFont.caption)
    }
}

extension View {
    /// The search's filter chips: a small capsule, tinted while it narrows the search.
    func searchFilterChip(isActive: Bool) -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(isActive ? DSColor.accent : DSColor.textSecondary)
    }

    /// The chips' row height. Applied after the chip's accessibility modifiers: on the frame,
    /// they make a container element around the control, and on iOS 17 activating that
    /// element (a VoiceOver double tap, an XCUITest tap) never opened 類型's menu (search 9e).
    func searchFilterChipRowHeight() -> some View {
        frame(minHeight: DSLayout.minimumTapTarget)
    }
}

#if DEBUG
#Preview("搜索：篩選條") {
    HStack {
        SearchKindFilterChip(model: UnifiedSearchModel(sourceURL: { _ in nil }))
        Button {} label: { SearchFilterChipLabel(title: "全部來源配置") }
            .searchFilterChip(isActive: false)
            .searchFilterChipRowHeight()
        Spacer()
    }
    .padding(.horizontal, DSSpacing.lg)
}
#endif
