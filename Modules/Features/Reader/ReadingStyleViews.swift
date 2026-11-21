import CoreText
import SwiftUI
import UIKit

// MARK: - Choices

/// One reading style as a row or a menu item: its name, and nothing drawn of it
/// (maintainer, 2026-11-21: no previews).
struct ReadingStyleChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The one place a reading style's tap is answered: Pro is asked here, where the reader
/// asks for the style, and nowhere in the code that wears a stored setup.
@MainActor
enum ReadingStyleActions {
    static func apply(
        styleID: String,
        isProActive: Bool,
        onOpenPaywall: (PremiumFeature) -> Void
    ) {
        guard isProActive else {
            onOpenPaywall(.readingStyles)
            return
        }
        let settings = GlobalSettings.shared
        do {
            if let builtIn = ReadingStyleLibrary.builtIn(id: styleID) {
                try settings.applyReadingStyle(builtIn)
            } else if let custom = settings.customReadingStyles.first(where: { $0.id == styleID }) {
                try settings.applyReadingStyle(custom)
            }
        } catch {
            // The header/footer layout could not be stored, so the writer stopped
            // before the rest (`writeReadingSettings`). Nothing was half-applied.
            AppLogger.error("⟐ reading style not applied", error: error, context: ["style": styleID])
        }
    }

    /// 未套用: free with or without Pro — it only takes a style off.
    static func remove() {
        do {
            try GlobalSettings.shared.removeReadingStyle()
        } catch {
            AppLogger.error("⟐ reading style not removed", error: error)
        }
    }

    /// The reader's own styles.
    static var mine: [ReadingStyleChoice] {
        GlobalSettings.shared.customReadingStyles.map { ReadingStyleChoice(id: $0.id, name: $0.name) }
    }

    /// The built-in styles by language, the interface language's first.
    static var builtInGroups: [(language: BuiltInReadingStyle.Language, styles: [ReadingStyleChoice])] {
        let own = BuiltInReadingStyle.Language.interface
        let languages = [own] + BuiltInReadingStyle.Language.allCases.filter { $0 != own }
        return languages.map { language in
            (language, ReadingStyleLibrary.builtIns.filter { $0.language == language }
                .map { ReadingStyleChoice(id: $0.id, name: localized($0.nameKey)) })
        }
    }
}

/// What a reading face is called on screen — one answer for 閱讀設定 and the Aa panel.
@MainActor
enum ReaderFontDisplayName {
    static func name(for postScriptName: String?, defaultName: String) -> String {
        guard let postScriptName, !postScriptName.isEmpty else { return defaultName }
        if let imported = GlobalSettings.shared.userFonts.first(where: { $0.postScriptName == postScriptName }) {
            return imported.displayName
        }
        // A system face a reading style named: its family in the interface language
        // (宋體-繁, Georgia), not the PostScript name. One not on the device yet — still
        // being fetched, or from another device — has only that name to show.
        guard let font = UIFont(name: postScriptName, size: 17) else { return postScriptName }
        return CTFontCopyLocalizedName(font as CTFont, kCTFontFamilyNameKey, nil) as String? ?? font.familyName
    }
}

// MARK: - Aa panel

/// The capsule a menu of the Aa panel opens from: what it sets, small, over what is set.
private struct QuickPanelMenuLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(DSFont.caption2)
                .foregroundStyle(DSColor.textSecondary)
            HStack(spacing: DSSpacing.xs) {
                Text(value).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(DSFont.footnote)
                    .accessibilityHidden(true)
            }
            .font(DSFont.subheadline)
            .foregroundStyle(DSColor.textPrimary)
        }
        .padding(.horizontal, DSSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: DSLayout.readerQuickPanelTopControlHeight)
        .background(DSColor.neutralControlFill, in: Capsule())
        .shadow(color: DSColor.shadow, radius: 6, y: 1)
        .contentShape(Capsule())
    }
}

/// 閱讀樣式 in the Aa panel: a menu of names — the reader's own, then the built-in ones by
/// language with the interface language's first.
struct ReadingStyleMenu: View {
    let isProActive: Bool
    let onOpenPaywall: (PremiumFeature) -> Void

    @Bindable private var settings = GlobalSettings.shared

    var body: some View {
        Menu {
            // First, and always free: the way back to the page before any style.
            Button {
                ReadingStyleActions.remove()
            } label: {
                if settings.readerReadingStyleID == nil {
                    Label(localized("ReadingStyle.None"), systemImage: "checkmark")
                } else {
                    Text(localized("ReadingStyle.None"))
                }
            }
            let mine = ReadingStyleActions.mine
            if !mine.isEmpty {
                Section(localized("ReadingStyle.Mine")) { items(mine) }
            }
            ForEach(ReadingStyleActions.builtInGroups, id: \.language) { group in
                Section(localized(group.language.titleKey)) { items(group.styles) }
            }
        } label: {
            QuickPanelMenuLabel(title: localized("閱讀樣式"), value: currentName)
        }
        .accessibilityLabel(localized("閱讀樣式"))
        .accessibilityValue(isProActive ? currentName : localized("需要 Pro"))
    }

    private var currentName: String {
        guard let name = settings.appliedReadingStyleName else { return localized("ReadingStyle.None") }
        return settings.isReadingStyleModified
            ? String(format: localized("ReadingStyle.ModifiedFormat"), name)
            : name
    }

    @ViewBuilder
    private func items(_ styles: [ReadingStyleChoice]) -> some View {
        ForEach(styles) { style in
            Button {
                ReadingStyleActions.apply(styleID: style.id, isProActive: isProActive, onOpenPaywall: onOpenPaywall)
            } label: {
                if !isProActive {
                    // Locked: the second `Text` is the menu row's subtitle.
                    Text(style.name)
                    Text(localized("需要 Pro"))
                    Image(systemName: "lock.fill")
                } else if settings.readerReadingStyleID == style.id {
                    Label(style.name, systemImage: "checkmark")
                } else {
                    Text(style.name)
                }
            }
        }
    }
}

/// 字體 in the Aa panel: the default face and the imported ones. Importing and deleting
/// stay in 閱讀設定, which has the file picker.
struct ReaderFontMenu: View {
    /// 「書籍預設字體」 for an EPUB, 「系統字體」 for the rest.
    let defaultName: String

    @Bindable private var settings = GlobalSettings.shared

    var body: some View {
        Menu {
            item(defaultName, postScriptName: nil)
            // A face a reading style named is not an imported one; it is listed while
            // it is the one in use, so the menu always shows what is selected.
            if let selected = settings.selectedReaderFontPostScript,
               !settings.userFonts.contains(where: { $0.postScriptName == selected }) {
                item(currentName, postScriptName: selected)
            }
            if !settings.userFonts.isEmpty {
                Section(localized("已匯入字體")) {
                    ForEach(settings.userFonts, id: \.id) { font in
                        item(font.displayName, postScriptName: font.postScriptName)
                    }
                }
            }
        } label: {
            QuickPanelMenuLabel(title: localized(ReadingSettingsScopeItem.font.titleKey), value: currentName)
        }
        .accessibilityLabel(localized(ReadingSettingsScopeItem.font.titleKey))
        .accessibilityValue(currentName)
    }

    private var currentName: String {
        ReaderFontDisplayName.name(for: settings.selectedReaderFontPostScript, defaultName: defaultName)
    }

    private func item(_ name: String, postScriptName: String?) -> some View {
        Button {
            settings.selectedReaderFontPostScript = postScriptName
        } label: {
            if settings.selectedReaderFontPostScript == postScriptName {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }
}

// MARK: - 閱讀樣式 page

/// 閱讀樣式 in 閱讀設定: which style is worn, the reader's own styles, every built-in one by
/// language, 只套用到這本書, and which rows are left on 自動.
struct ReadingStylesView: View {
    let isProActive: Bool
    let onOpenPaywall: (PremiumFeature) -> Void

    @Bindable private var settings = GlobalSettings.shared
    @State private var showingSavePrompt = false
    @State private var styleName = ""
    @State private var renamingStyleID: String?

    var body: some View {
        Form {
            currentSection
            mineSection
            ForEach(ReadingStyleActions.builtInGroups, id: \.language) { group in
                Section {
                    ForEach(group.styles) { style in styleRow(style) }
                } header: {
                    Text(localized(group.language.titleKey)).foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
            thisBookSection
            automaticSection
        }
        .softScrollEdges()
        .themedAppSurface(for: .settings)
        .navigationTitle(localized("閱讀樣式"))
        .toolbarTitleDisplayMode(.inline)
        .alert(localized(renamingStyleID == nil ? "ReadingStyle.SaveNew" : "重新命名"), isPresented: $showingSavePrompt) {
            TextField(localized("ReadingStyle.Name.Prompt"), text: $styleName)
            Button(localized("取消"), role: .cancel) { renamingStyleID = nil }
            Button(localized("儲存")) { commitName() }
                .disabled(styleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// A style by name: a checkmark on the one in use, a lock without Pro.
    private func styleRow(_ style: ReadingStyleChoice) -> some View {
        let isSelected = settings.readerReadingStyleID == style.id
        return Button {
            ReadingStyleActions.apply(styleID: style.id, isProActive: isProActive, onOpenPaywall: onOpenPaywall)
        } label: {
            HStack {
                Text(style.name).foregroundStyle(DSColor.textPrimary)
                Spacer()
                if !isProActive {
                    ProLockBadge()
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Sections

    private var currentSection: some View {
        Section {
            LabeledContent {
                Text(currentStyleText).foregroundStyle(DSColor.textSecondary)
            } label: {
                SettingsRowLabel(localized("ReadingStyle.Current"), systemImage: "rectangle.stack")
            }
            if settings.readerReadingStyleID != nil {
                Button {
                    ReadingStyleActions.remove()
                } label: {
                    SettingsRowLabel(localized("ReadingStyle.Remove"), systemImage: "xmark.circle")
                }
            }
            if let name = settings.appliedReadingStyleName, settings.isReadingStyleModified {
                Button {
                    restoreAppliedStyle()
                } label: {
                    SettingsRowLabel(String(format: localized("ReadingStyle.Restore"), name),
                                     systemImage: "arrow.uturn.backward")
                }
            }
        }
        .interfaceSectionSurface()
    }

    private var currentStyleText: String {
        guard let name = settings.appliedReadingStyleName else { return localized("ReadingStyle.None") }
        return settings.isReadingStyleModified
            ? String(format: localized("ReadingStyle.ModifiedFormat"), name)
            : name
    }

    private var mineSection: some View {
        Section {
            ForEach(ReadingStyleActions.mine) { style in
                styleRow(style)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        settings.deleteCustomReadingStyle(id: style.id)
                    } label: {
                        Label(localized("刪除"), systemImage: "trash")
                    }
                    Button {
                        renamingStyleID = style.id
                        styleName = style.name
                        showingSavePrompt = true
                    } label: {
                        Label(localized("重新命名"), systemImage: "pencil")
                    }
                }
            }
            if isProActive {
                Button {
                    renamingStyleID = nil
                    styleName = ""
                    showingSavePrompt = true
                } label: {
                    SettingsRowLabel(localized("ReadingStyle.SaveNew"), systemImage: "plus")
                }
            } else {
                SettingsLockedRow(title: localized("ReadingStyle.SaveNew"), systemImage: "plus") {
                    onOpenPaywall(.readingStyles)
                }
            }
        } header: {
            Text(localized("ReadingStyle.Mine")).foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(localized("ReadingStyle.Mine.Footer")).dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var thisBookSection: some View {
        Section {
            if isProActive {
                Toggle(isOn: Binding(
                    get: { settings.bookReadingOverride != nil },
                    set: { settings.setReadingSetupIsThisBooksOwn($0) }
                )) {
                    SettingsRowLabel(localized("ReadingStyle.ThisBookOnly"), systemImage: "book.closed")
                }
            } else {
                SettingsLockedRow(title: localized("ReadingStyle.ThisBookOnly"), systemImage: "book.closed") {
                    onOpenPaywall(.readingStyles)
                }
            }
        } footer: {
            Text(localized("ReadingStyle.ThisBookOnly.Footer")).dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    private var automaticSection: some View {
        Section {
            ForEach(Self.automaticRows) { item in
                Toggle(isOn: Binding(
                    get: { settings.readerAutomaticItems.contains(item) },
                    set: { settings.setReadingRowAutomatic(item, $0) }
                )) {
                    SettingsRowLabel(localized(item.titleKey), systemImage: item.systemImage)
                }
            }
        } header: {
            Text(localized("ReadingStyle.Automatic.Title")).foregroundStyle(DSColor.textSecondary)
        } footer: {
            Text(String(format: localized("ReadingStyle.Automatic.Footer"),
                        localized(settings.readingBaseline.titleKey)))
                .dsSectionFooter()
        }
        .interfaceSectionSurface()
    }

    /// In 閱讀設定's order.
    private static let automaticRows: [ReadingSettingsScopeItem] = [
        .font, .fontSize, .bold, .lineSpacing, .letterSpacing, .paragraphSpacing,
        .firstLineIndent, .textAlignment, .pageMargins,
    ]

    // MARK: Actions

    private func restoreAppliedStyle() {
        guard let id = settings.readerReadingStyleID else { return }
        // Applying a style again, so asked like any other: without Pro it opens the paywall.
        ReadingStyleActions.apply(styleID: id, isProActive: isProActive, onOpenPaywall: onOpenPaywall)
    }

    private func commitName() {
        let name = styleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let id = renamingStyleID {
            settings.renameCustomReadingStyle(id: id, to: name)
        } else {
            settings.saveCurrentReadingSetupAsStyle(named: name)
        }
        renamingStyleID = nil
    }
}

#Preview("閱讀樣式") {
    NavigationStack {
        ReadingStylesView(isProActive: true, onOpenPaywall: { _ in })
    }
}

#Preview("Aa 面板選單") {
    HStack {
        ReadingStyleMenu(isProActive: false, onOpenPaywall: { _ in })
        ReaderFontMenu(defaultName: localized("系統字體"))
    }
    .padding()
}
