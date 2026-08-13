import SwiftUI

// MARK: - Why these are their own View structs
//
// `List` defers a child view's `body`; it does NOT defer construction of the view
// value a `ForEach` closure returns — and it calls that closure for every element
// (measured: twice per element). While the source row was built by `@ViewBuilder`
// methods on `BookSourceListView`, opening 書源管理 therefore constructed all N rows
// up front: two `Menu` trees per row (~25 items each), the merged row's rotor
// actions, a `ShareLink`, and one full-table scan for the group-name submenus.
// With 3000 imported sources that was ~1.4 s of blocked main thread and 250–345 MB
// resident on a simulator — on device, a screen that never opens.
//
// Measured with a 3000-source list (60 groups): row trees built 6000 → 9, menus
// 6000 → 9, resident 252 MB → 224 MB, main-thread block ~1.4 s → none. The rule this
// encodes: anything inside a `List` row that is more than a couple of views must be
// reached through a `View` struct, never assembled by a method on the parent.
//
// The group-name submenus are gone for the same reason — they built one `Button` per group
// per row, and ran a full pass over `BookSourceStore.sources` to do it. Both now open
// `BookSourceGroupPickerSheet`, which asks `store.groupCounts(excluding:)` once, on open.

/// One row group in the management list. Every displayed source belongs to exactly one
/// group: pinned sources land in the built-in 置頂／置底 groups, the rest use their
/// `bookSourceGroup` — and sources without one land in the built-in 默認分組 (Legado's
/// default group — ungrouped sources are never left flat).
struct BookSourceRowGroup: Identifiable {
    /// Sentinel ids for the built-in 置頂／置底 groups — kept distinct from any user group
    /// name, so a group literally named 置頂 cannot collide with them.
    static let topPinnedID = "yuedu.pin-group.top"
    static let bottomPinnedID = "yuedu.pin-group.bottom"

    let id: String
    let name: String
    let sources: [BookSource]

    /// 置頂／置底 are synthetic buckets built from pin state, not from `bookSourceGroup`.
    /// Renaming, merging, or deleting "the group" is meaningless for them, so their menu
    /// only offers the operations that act on the member sources.
    var isPinGroup: Bool {
        id == Self.topPinnedID || id == Self.bottomPinnedID
    }

    /// Computed, not stored: it is only read inside the group menu, which is part of the
    /// deferred `body`. Storing it would put an O(group size) pass back into construction.
    var sourceIds: Set<UUID> { Set(sources.map(\.id)) }
}

/// Native share row for 匯出 …（儲存到「檔案」／AirDrop／…）. See `BookSourceExportFile` for
/// why this is a `ShareLink` and not a `.fileExporter`.
struct BookSourceExportShareLink: View {
    let label: String
    let filenameLabel: String
    let sources: [BookSource]

    var body: some View {
        let file = BookSourceExportFile(
            filename: BookSourceExportFile.filename(for: filenameLabel), sources: sources)
        ShareLink(item: file, preview: SharePreview(file.filename)) {
            Label(label, systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Source Row

/// Everything a source row's controls, menu and rotor actions can do. Built once by
/// `BookSourceListView` and handed to every row, so constructing a row costs a few
/// closure retains instead of re-deriving the parent's state.
struct BookSourceRowActions {
    var toggleSelection: (UUID) -> Void
    var toggleEnabled: (UUID) -> Void
    var showInfo: (BookSource) -> Void
    var test: (BookSource) -> Void
    var edit: (BookSource) -> Void
    var copyJSON: (BookSource) -> Void
    var login: (BookSource) -> Void
    var editVariables: (BookSource) -> Void
    /// Writes a group name to a set of sources; the built-in default group clears the field.
    var applyGroupName: (String, Set<UUID>) -> Void
    /// Opens 移動到分組 — a searchable group list, not a submenu. See
    /// `BookSourceGroupPickerSheet` for why the submenu is gone.
    var pickGroup: (BookSource) -> Void
    var moveToNewGroup: (BookSource) -> Void
    var pinToTop: (BookSource) -> Void
    var pinToBottom: (BookSource) -> Void
    /// The announcement is the caller's, because only the row knows which pin it is dropping.
    var unpin: (BookSource, String) -> Void
    var delete: (BookSource) -> Void
}

/// One VoiceOver element per source.
///
/// The row packs five separate controls (核取方塊 / 啟用開關 / 編輯 / 更多) around three
/// lines of text, so unmerged it cost eight swipes per source and announced bare SF
/// Symbol names ("square", "square.and.pencil", "ellipsis") for four of them. Merging
/// means every control has to come back as a rotor action — see `rotorActions` — and the
/// 網址 moves to rotor custom content so it isn't re-read on every swipe.
/// Rules in `docs/design.md` §7.
struct BookSourceRow: View {
    let source: BookSource
    let isSelected: Bool
    let pin: SourcePinPosition?
    let health: SourceValidationSummary?
    /// Display label of the built-in group for sources with no `bookSourceGroup`.
    let defaultGroupName: String
    let actions: BookSourceRowActions

    /// Leading slot for the 置頂／置底 pin icon, matching the old warning bar + checkbox
    /// padding so source names keep their horizontal position.
    private let pinSlotWidth = DSSpacing.lg + DSSpacing.xs

    @ViewBuilder
    var body: some View {
        let row = content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(accessibilityTraits)
            .accessibilityHint(localized("點兩下切換啟用狀態"))
            .accessibilityAction { actions.toggleEnabled(source.id) }
            .accessibilityActions { rotorActions }

        if source.bookSourceUrl.isEmpty {
            row
        } else {
            row.accessibilityCustomContent(
                Text(localized("網址")),
                Text(source.bookSourceUrl)
            )
        }
    }

    // MARK: Visible content

    private var content: some View {
        HStack(spacing: 0) {
            pinIndicator

            Button {
                actions.toggleSelection(source.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(DSFont.fixed(size: 20))
                    .foregroundColor(isSelected ? DSColor.accent : Color(UIColor.systemGray3))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName.isEmpty
                        ? localized("未命名書源") : source.bookSourceName)
                        .font(DSFont.toolbarIcon)
                        .foregroundColor(source.enabled ? .primary : .secondary)
                        .lineLimit(1)

                    if !source.bookSourceGroup.isEmpty {
                        Text("(\(source.bookSourceGroup))")
                            .font(DSFont.fixed(size: 13))
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                if !source.bookSourceUrl.isEmpty {
                    Text(source.bookSourceUrl)
                        .font(DSFont.fixed(size: 11))
                        .foregroundColor(DSColor.textSecondary.opacity(0.6))
                        .lineLimit(1)
                }
                SourceValidationBadge(summary: health)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                "",
                isOn: Binding(
                    get: { source.enabled },
                    set: { _ in actions.toggleEnabled(source.id) }
                )
            )
            .labelsHidden()
            .scaleEffect(0.85)
            .padding(.trailing, 4)

            Button {
                actions.edit(source)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            menu
                .padding(.trailing, 12)
        }
        .padding(.vertical, 14)
        .opacity(source.enabled ? 1 : 0.6)
    }

    /// 置頂／置底 marker: a pin icon instead of the old warning-colored bar, so only sources
    /// the user explicitly pinned carry an indicator (the first unpinned source does not).
    @ViewBuilder
    private var pinIndicator: some View {
        if let pin {
            Image(systemName: "pin.fill")
                .font(DSFont.fixed(size: 12))
                .foregroundColor(DSColor.accent)
                .rotationEffect(.degrees(pin == .bottom ? 180 : 0))
                .frame(width: pinSlotWidth)
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: pinSlotWidth)
                .accessibilityHidden(true)
        }
    }

    private var menu: some View {
        Menu {
            Button {
                actions.showInfo(source)
            } label: {
                Label(localized("查看詳情"), systemImage: "info.circle")
            }
            Button {
                actions.test(source)
            } label: {
                Label(localized("測試書源"), systemImage: "stethoscope")
            }
            Button {
                actions.edit(source)
            } label: {
                Label(localized("編輯"), systemImage: "pencil")
            }
            if !source.loginUrl.isEmpty {
                Button {
                    actions.login(source)
                } label: {
                    Label(localized("Cookie 驗證登入"), systemImage: "key.fill")
                }
            }
            Button {
                actions.toggleSelection(source.id)
            } label: {
                Label(
                    localized(isSelected ? "取消選取" : "選取此書源"),
                    systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.circle")
            }
            Divider()
            Button {
                actions.toggleEnabled(source.id)
            } label: {
                Label(
                    localized(source.enabled ? "停用" : "啟用"),
                    systemImage: source.enabled ? "pause.circle" : "play.circle")
            }
            Button {
                actions.pickGroup(source)
            } label: {
                Label(localized("移動到分組"), systemImage: "folder")
            }
            Button {
                actions.editVariables(source)
            } label: {
                Label(localized("設置源變量"), systemImage: "curlybraces")
            }
            Divider()
            BookSourceExportShareLink(
                label: localized("匯出書源檔案"),
                filenameLabel: source.bookSourceName.isEmpty
                    ? localized("未命名書源") : source.bookSourceName,
                sources: [source]
            )
            Button {
                actions.copyJSON(source)
            } label: {
                Label(localized("複製 JSON"), systemImage: "doc.on.doc")
            }
            Divider()
            if pin == .top {
                Button {
                    actions.unpin(source, localized("已取消置頂"))
                } label: {
                    Label(localized("取消置頂"), systemImage: "pin.slash")
                }
            } else {
                Button {
                    actions.pinToTop(source)
                } label: {
                    Label(localized("置頂"), systemImage: "arrow.up.to.line")
                }
            }
            if pin == .bottom {
                Button {
                    actions.unpin(source, localized("已取消置底"))
                } label: {
                    Label(localized("取消置底"), systemImage: "pin.slash")
                }
            } else {
                Button {
                    actions.pinToBottom(source)
                } label: {
                    Label(localized("置底"), systemImage: "arrow.down.to.line")
                }
            }
            Divider()
            Button(role: .destructive) {
                actions.delete(source)
            } label: {
                Label(localized("刪除"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.toolbarIcon)
                .foregroundColor(DSColor.textSecondary)
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(90))
        }
    }

    // MARK: Accessibility

    /// The row's VoiceOver name: 書源名稱（分組）, matching the first visible line.
    private var accessibilityLabel: String {
        let name = source.bookSourceName.isEmpty
            ? localized("未命名書源")
            : source.bookSourceName
        guard !source.bookSourceGroup.isEmpty else { return name }
        return "\(name)（\(source.bookSourceGroup)）"
    }

    /// State the row shows visually: the 啟用 toggle, the pin marker, and the validation badge.
    /// Selection is carried by the `.isSelected` trait instead, so it isn't said twice.
    private var accessibilityValue: String {
        var parts = [localized(source.enabled ? "已啟用" : "已停用")]
        if let pin {
            parts.append(localized(pin == .top ? "已置頂" : "已置底"))
        }
        if let health = health?.health {
            parts.append(Self.healthText(health))
        }
        return parts.joined(separator: "，")
    }

    /// `.isSelected` is what carries the leading checkbox — VoiceOver says 「已選取」 for it,
    /// so the value line stays about 啟用 state only.
    private var accessibilityTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if isSelected {
            // SwiftUI's `AccessibilityTraits.insert` is not `@discardableResult`.
            _ = traits.insert(.isSelected)
        }
        return traits
    }

    static func healthText(_ health: SourceHealth) -> String {
        switch health {
        case .passed:       return localized("驗證通過")
        case .fetchError:   return localized("抓取異常")
        case .contentError: return localized("正文異常")
        }
    }

    /// Everything the row's buttons and menu can do, as rotor actions. Must stay in sync
    /// with the visible controls in `content` — the merged element is the only way
    /// VoiceOver can reach any of them.
    @ViewBuilder
    private var rotorActions: some View {
        Button(localized(isSelected ? "取消選取" : "選取")) {
            actions.toggleSelection(source.id)
        }
        Button(localized("查看詳情")) {
            actions.showInfo(source)
        }
        Button(localized("測試書源")) {
            actions.test(source)
        }
        Button(localized("編輯")) {
            actions.edit(source)
        }
        Button(localized("複製 JSON")) {
            actions.copyJSON(source)
        }
        if !source.loginUrl.isEmpty {
            Button(localized("Cookie 驗證登入")) {
                actions.login(source)
            }
        }
        Button(localized("設置源變量")) {
            actions.editVariables(source)
        }
        // 移動到分組 is now a searchable list rather than a submenu of group names, so the
        // rotor can reach the real thing. 移動到新分組 stays as the quicker typing path.
        Button(localized("移動到分組")) {
            actions.pickGroup(source)
        }
        Button(localized("移動到新分組")) {
            actions.moveToNewGroup(source)
        }
        if !source.bookSourceGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(localized("移出分組")) {
                actions.applyGroupName(defaultGroupName, [source.id])
            }
        }
        if pin == .top {
            Button(localized("取消置頂")) {
                actions.unpin(source, localized("已取消置頂"))
            }
        } else {
            Button(localized("置頂")) {
                actions.pinToTop(source)
            }
        }
        if pin == .bottom {
            Button(localized("取消置底")) {
                actions.unpin(source, localized("已取消置底"))
            }
        } else {
            Button(localized("置底")) {
                actions.pinToBottom(source)
            }
        }
        Button(localized("刪除"), role: .destructive) {
            actions.delete(source)
        }
    }
}

// MARK: - Group Header Row

/// Group-level operations, built once by `BookSourceListView` like `BookSourceRowActions`.
struct BookSourceGroupActions {
    var toggleExpansion: (String) -> Void
    var rename: (BookSourceRowGroup) -> Void
    /// Opens 合併到其他分組 — the same searchable group list the rows use.
    var pickMergeTarget: (BookSourceRowGroup) -> Void
    var setEnabled: (Set<UUID>, Bool) -> Void
    var select: (Set<UUID>) -> Void
    var copyToPasteboard: (BookSourceRowGroup) -> Void
    var delete: (BookSourceRowGroup) -> Void
}

/// 「› 分組名 12 ⋯」 — the chevron leads the title (Legado's layout) and the whole title
/// area toggles the group; the trailing menu holds the group-level operations.
struct BookSourceGroupHeaderRow: View {
    let group: BookSourceRowGroup
    let expanded: Bool
    let actions: BookSourceGroupActions

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Button {
                actions.toggleExpansion(group.id)
            } label: {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(DSFont.caption.weight(.semibold))
                        .foregroundColor(DSColor.textSecondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: DSSpacing.md)
                        .accessibilityHidden(true)
                    Text(group.name)
                        .font(DSFont.toolbarIcon)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(group.sources.count)")
                        .font(DSFont.fixed(size: 12))
                        .foregroundColor(DSColor.textSecondary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name)，\(group.sources.count)")
            .accessibilityValue(localized(expanded ? "已展開" : "已收合"))
            .accessibilityHint(localized("點兩下展開或收合分組"))
            .accessibilityAddTraits(.isHeader)

            menu
        }
    }

    /// 分組操作 menu — Legado's group actions. Rename / merge / delete are hidden for the
    /// synthetic 置頂／置底 buckets, which have no `bookSourceGroup` to act on.
    private var menu: some View {
        Menu {
            if !group.isPinGroup {
                Button {
                    actions.rename(group)
                } label: {
                    Label(localized("重命名分組"), systemImage: "pencil")
                }
                Button {
                    actions.pickMergeTarget(group)
                } label: {
                    Label(localized("合併到其他分組"), systemImage: "arrow.triangle.merge")
                }
                Divider()
            }
            Button {
                actions.setEnabled(group.sourceIds, true)
            } label: {
                Label(localized("啟用全部"), systemImage: "play.circle")
            }
            Button {
                actions.setEnabled(group.sourceIds, false)
            } label: {
                Label(localized("停用全部"), systemImage: "pause.circle")
            }
            Divider()
            Button {
                actions.select(group.sourceIds)
            } label: {
                Label(localized("選擇該分組"), systemImage: "checkmark.circle")
            }
            BookSourceExportShareLink(
                label: localized("匯出該分組"),
                filenameLabel: group.name,
                sources: group.sources
            )
            Button {
                actions.copyToPasteboard(group)
            } label: {
                Label(localized("複製該分組到剪貼簿"), systemImage: "doc.on.doc")
            }
            if !group.isPinGroup {
                Divider()
                Button(role: .destructive) {
                    actions.delete(group)
                } label: {
                    Label(localized("刪除該分組"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(DSFont.toolbarIcon)
                .foregroundColor(DSColor.textSecondary)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .accessibilityLabel(localized("分組操作"))
    }
}

// MARK: - Previews

private func previewSource(
    name: String, group: String = "", enabled: Bool = true
) -> BookSource {
    var source = BookSource(bookSourceUrl: "https://example.com/\(name)", bookSourceName: name)
    source.bookSourceGroup = group
    source.enabled = enabled
    return source
}

private let previewActions = BookSourceRowActions(
    toggleSelection: { _ in }, toggleEnabled: { _ in }, showInfo: { _ in }, test: { _ in },
    edit: { _ in }, copyJSON: { _ in }, login: { _ in }, editVariables: { _ in },
    applyGroupName: { _, _ in }, pickGroup: { _ in }, moveToNewGroup: { _ in },
    pinToTop: { _ in },
    pinToBottom: { _ in }, unpin: { _, _ in }, delete: { _ in }
)

#Preview("書源列") {
    List {
        BookSourceRow(
            source: previewSource(name: "示例書源", group: "常用"),
            isSelected: false, pin: nil, health: nil, defaultGroupName: "默認分組",
            actions: previewActions
        )
        BookSourceRow(
            source: previewSource(name: "已選取的源"),
            isSelected: true, pin: .top, health: nil, defaultGroupName: "默認分組",
            actions: previewActions
        )
        BookSourceRow(
            source: previewSource(name: "已停用的源", group: "備用", enabled: false),
            isSelected: false, pin: .bottom, health: nil, defaultGroupName: "默認分組",
            actions: previewActions
        )
    }
    .listStyle(.plain)
}

#Preview("分組表頭") {
    List {
        BookSourceGroupHeaderRow(
            group: BookSourceRowGroup(
                id: "常用", name: "常用",
                sources: [previewSource(name: "A"), previewSource(name: "B")]),
            expanded: true,
            actions: BookSourceGroupActions(
                toggleExpansion: { _ in }, rename: { _ in }, pickMergeTarget: { _ in },
                setEnabled: { _, _ in }, select: { _ in }, copyToPasteboard: { _ in },
                delete: { _ in })
        )
        BookSourceGroupHeaderRow(
            group: BookSourceRowGroup(
                id: BookSourceRowGroup.topPinnedID, name: "置頂組",
                sources: [previewSource(name: "C")]),
            expanded: false,
            actions: BookSourceGroupActions(
                toggleExpansion: { _ in }, rename: { _ in }, pickMergeTarget: { _ in },
                setEnabled: { _, _ in }, select: { _ in }, copyToPasteboard: { _ in },
                delete: { _ in })
        )
    }
    .listStyle(.plain)
}
