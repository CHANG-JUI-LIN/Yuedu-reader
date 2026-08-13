import SwiftUI

/// One selectable destination group, with how many sources it already holds.
struct BookSourceGroupCandidate: Identifiable, Hashable {
    let name: String
    let count: Int

    var id: String { name }
}

/// 移動到分組 (one source) and 合併到其他分組 (a whole group) — one searchable list instead
/// of a menu that expanded every group name.
///
/// The old submenu listed one menu row per group. That is fine for a handful of groups and
/// unusable past a few dozen: `Menu` content is built eagerly with its parent, iOS gives a
/// menu no search field, and a pack imported with 按域名分組 can produce over a thousand
/// groups. A `List` is lazy, searchable, and can show each group's size.
///
/// Both entry points end in the same `applyGroupName` write, so there is one path for
/// "put these sources in that group" no matter which menu opened it.
struct BookSourceGroupPickerSheet: View {
    let title: String
    /// What the pick applies to — the source's name, or 分組名 · N 個書源.
    let subtitle: String
    /// Destination groups, already excluding the current one, in first-appearance order.
    let candidates: [BookSourceGroupCandidate]
    /// The group the pick came from; offering to create it again would be a no-op.
    let excluded: String
    /// Label for the row that clears `bookSourceGroup` — 移出分組 for one source, 默認分組
    /// when merging a whole group. Absent when the source is already ungrouped.
    let defaultGroupTitle: String?
    /// Display name of the built-in default group. Selecting the row above hands *this*
    /// back, not the label — `applyGroupName` reads it as "clear `bookSourceGroup`", and
    /// handing back 「移出分組」 would create a group literally called that.
    let defaultGroupName: String
    /// Whether the search text can be committed as a brand-new group. A whole group renames
    /// instead, so 合併到其他分組 leaves this off.
    let allowsNewGroup: Bool
    let onSelect: (String) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredCandidates: [BookSourceGroupCandidate] {
        guard !trimmedQuery.isEmpty else { return candidates }
        let needle = trimmedQuery.lowercased()
        return candidates.filter { $0.name.lowercased().contains(needle) }
    }

    /// The 移出分組／默認分組 row hides while the search text can't match it, so searching
    /// narrows the whole sheet rather than leaving one row pinned at the top.
    private var showsDefaultGroupRow: Bool {
        guard let defaultGroupTitle else { return false }
        guard !trimmedQuery.isEmpty else { return true }
        return defaultGroupTitle.lowercased().contains(trimmedQuery.lowercased())
    }

    /// 新增分組「⋯」 — offered only for a name that doesn't exist yet.
    private var newGroupName: String? {
        guard allowsNewGroup, !trimmedQuery.isEmpty, trimmedQuery != excluded else { return nil }
        guard !candidates.contains(where: { $0.name == trimmedQuery }) else { return nil }
        return trimmedQuery
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(subtitle)
                        .font(DSFont.footnote)
                        .foregroundColor(DSColor.textSecondary)
                }
                .listRowBackground(Color.clear)

                if showsDefaultGroupRow, let defaultGroupTitle {
                    Section {
                        Button {
                            select(defaultGroupName)
                        } label: {
                            Label(defaultGroupTitle, systemImage: "folder.badge.minus")
                                .foregroundColor(DSColor.textPrimary)
                        }
                    }
                    .interfaceSectionSurface()
                }

                if !filteredCandidates.isEmpty {
                    Section {
                        ForEach(filteredCandidates) { candidate in
                            Button {
                                select(candidate.name)
                            } label: {
                                HStack(spacing: DSSpacing.sm) {
                                    Text(candidate.name)
                                        .foregroundColor(DSColor.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: DSSpacing.sm)
                                    Text("\(candidate.count)")
                                        .font(DSFont.subheadline)
                                        .foregroundColor(DSColor.textSecondary)
                                        .monospacedDigit()
                                }
                            }
                            .accessibilityLabel(candidate.name)
                            .accessibilityValue("\(candidate.count) " + localized("個書源"))
                        }
                    }
                    .interfaceSectionSurface()
                }

                if let newGroupName {
                    Section {
                        Button {
                            select(newGroupName)
                        } label: {
                            Label(
                                localized("新增分組") + "「\(newGroupName)」",
                                systemImage: "folder.badge.plus"
                            )
                            .foregroundColor(DSColor.accent)
                        }
                    }
                    .interfaceSectionSurface()
                }

                if filteredCandidates.isEmpty && !showsDefaultGroupRow && newGroupName == nil {
                    Section {
                        Text(localized("沒有符合的分組"))
                            .font(DSFont.subheadline)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜索分組")
            )
            .navigationTitle(title)
            // Modal sheet — `.inline`, never `.inlineLarge` (docs/design.md).
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text(localized("取消"))
                    }
                }
            }
        }
    }

    private func select(_ name: String) {
        onSelect(name)
        dismiss()
    }
}

#Preview("移動到分組") {
    BookSourceGroupPickerSheet(
        title: "移動到分組",
        subtitle: "示例書源",
        candidates: [
            BookSourceGroupCandidate(name: "言情", count: 124),
            BookSourceGroupCandidate(name: "玄幻", count: 88),
            BookSourceGroupCandidate(name: "m.qidian.com", count: 4),
        ],
        excluded: "聚合源",
        defaultGroupTitle: "移出分組",
        defaultGroupName: "默認分組",
        allowsNewGroup: true,
        onSelect: { _ in }
    )
}

#Preview("合併到其他分組 — 空") {
    BookSourceGroupPickerSheet(
        title: "合併到其他分組",
        subtitle: "言情 · 124 個書源",
        candidates: [],
        excluded: "言情",
        defaultGroupTitle: "默認分組",
        defaultGroupName: "默認分組",
        allowsNewGroup: false,
        onSelect: { _ in }
    )
}
