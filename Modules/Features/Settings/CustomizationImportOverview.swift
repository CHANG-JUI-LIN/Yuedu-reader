import Combine
import SwiftUI

// MARK: - Reading setup parts

/// One part of a reading setup, named the way 閱讀設定 names it. The pre-import alert
/// lists these so a pack cannot pass for "just the header/footer", and the 匯入完成
/// sheet shows the same list as what actually landed.
enum ReadingSetupPart: CaseIterable, Hashable {
    case font
    case layout
    case pageTurn
    case headerFooter
    case chapterTitle
    case background
    case commentBubble
    case dialogueBubble
    case regexHighlights
    case textDecoration

    var titleKey: String {
        switch self {
        case .font: return "字體"
        case .layout: return "排版"
        case .pageTurn: return "翻頁方式"
        case .headerFooter: return "頁首頁尾"
        case .chapterTitle: return "章節標題樣式"
        // Its own key: the shared 閱讀背景 is lower-case English, written for use
        // inside a sentence rather than as a row title.
        case .background: return "ReadingSetup.Background"
        case .commentBubble: return "段評氣泡"
        case .dialogueBubble: return "對話氣泡"
        case .regexHighlights: return "正則高亮"
        case .textDecoration: return "文字顏色與底線"
        }
    }

    /// The 排版生效範圍 rows this part is made of — the one mapping from fields to what
    /// 閱讀設定 calls them.
    var scopeItems: Set<ReadingSettingsScopeItem> {
        switch self {
        case .font: return [.font]
        case .layout: return [.fontSize, .bold, .lineSpacing, .letterSpacing, .paragraphSpacing, .pageMargins, .bottomJustify]
        case .pageTurn: return [.pageTurn]
        case .headerFooter: return [.headerFooter]
        case .chapterTitle: return [.chapterTitle]
        case .background: return [.background]
        case .commentBubble: return [.commentBubble]
        case .dialogueBubble: return [.dialogueBubble]
        case .regexHighlights: return [.regexHighlight]
        case .textDecoration: return [.textColor, .textUnderline]
        }
    }

    /// The symbol 閱讀設定 gives the control; 排版 has no single control, so it takes
    /// the type size's.
    var systemImage: String {
        switch self {
        case .font: return ReadingSettingsScopeItem.font.systemImage
        case .layout: return ReadingSettingsScopeItem.fontSize.systemImage
        case .pageTurn: return ReadingSettingsScopeItem.pageTurn.systemImage
        case .headerFooter: return ReadingSettingsScopeItem.headerFooter.systemImage
        case .chapterTitle: return ReadingSettingsScopeItem.chapterTitle.systemImage
        case .background: return ReadingSettingsScopeItem.background.systemImage
        case .commentBubble: return ReadingSettingsScopeItem.commentBubble.systemImage
        case .dialogueBubble: return ReadingSettingsScopeItem.dialogueBubble.systemImage
        case .regexHighlights: return ReadingSettingsScopeItem.regexHighlight.systemImage
        case .textDecoration: return ReadingSettingsScopeItem.textUnderline.systemImage
        }
    }

    /// The parts a setup speaks for, in 閱讀設定's order.
    static func parts(in reading: AppearanceThemeReadingSettings) -> [ReadingSetupPart] {
        let items = reading.items
        return allCases.filter { !$0.scopeItems.isDisjoint(with: items) }
    }

    /// 「字體、排版和頁首頁尾」 — joined the way the current language joins a list.
    static func localizedList(_ parts: [ReadingSetupPart]) -> String {
        ListFormatter.localizedString(byJoining: parts.map { localized($0.titleKey) })
    }
}

// MARK: - Pre-import question

/// The alert asked after a reading-settings file parsed and before anything lands. Built
/// here so both entry points — 閱讀設定 › 匯入閱讀設定 and a file opened from another app —
/// ask the same question in the same words.
///
/// A theme pack asks nothing: its reading setup is its theme's own, worn while the theme
/// is and switched away with it. It used to ask 跟隨主題 or 取代全域設定 (2026-09-29).
struct CustomizationImportPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    /// The one answer besides 取消. Drawn red: the file overwrites the settings it names.
    static let confirmTitleKey = "取代"

    /// A reading-settings file. It lands like an edit, setting by setting: on the worn
    /// theme for what follows the theme, in 全域 for the rest — so the message names the
    /// theme whenever part of the file will go there.
    static func readingSettings(
        named name: String?,
        parts: [ReadingSetupPart],
        themeName: String?
    ) -> Self {
        let list = ReadingSetupPart.localizedList(parts)
        let contents: String
        if let name, !name.isEmpty {
            contents = String(format: localized("「%@」包含%@。"), name, list)
        } else {
            contents = String(format: localized("這個檔案包含%@。"), list)
        }
        let consequence = themeName.map {
            String(format: localized("跟隨主題的設定會存進「%@」，其餘取代全域設定。"), $0)
        } ?? localized("會取代全域閱讀設定。")
        return CustomizationImportPrompt(
            title: localized("取代目前的閱讀設定？"),
            message: contents + consequence
        )
    }
}

extension View {
    /// The pre-import alert for the SwiftUI entry point. `pending` carries the parsed
    /// file, so the answer arrives together with what it applies to.
    ///
    /// A sheet may be presented straight from `onConfirm`: SwiftUI's alert runs its
    /// actions from the `UIAlertAction` handler, after the alert has been dismissed.
    func customizationImportPrompt<Pending>(
        _ pending: Binding<Pending?>,
        prompt: @escaping (Pending) -> CustomizationImportPrompt,
        onConfirm: @escaping (Pending) -> Void
    ) -> some View {
        alert(
            pending.wrappedValue.map { prompt($0).title } ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            presenting: pending.wrappedValue
        ) { item in
            Button(localized(CustomizationImportPrompt.confirmTitleKey), role: .destructive) {
                pending.wrappedValue = nil
                onConfirm(item)
            }
            Button(localized("取消"), role: .cancel) {
                pending.wrappedValue = nil
            }
        } message: { item in
            Text(prompt(item).message)
        }
    }
}

// MARK: - Overview

/// What an import changed, for the 匯入完成 sheet: what the file brought in, where its
/// reading setup went, and what did not come across exactly.
struct CustomizationImportOverview {
    struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let systemImage: String
        let detail: String?

        init(titleKey: String, systemImage: String, detail: String? = nil) {
            self.id = titleKey
            self.title = localized(titleKey)
            self.systemImage = systemImage
            self.detail = detail
        }
    }

    /// Where an imported reading setup ended up.
    enum ReadingPlacement: Equatable {
        /// A theme pack: its setup is its theme's own, worn while the theme is.
        case followsTheme(name: String)
        /// Every setting in the file follows the theme, so all of it went there.
        case theme(name: String)
        /// Some settings went to the theme they follow, the rest into 全域.
        case split(themeName: String)
        /// Written into 全域, the setup every theme falls back on.
        case global

        /// Where an import of `reading` into the current setup lands, setting by
        /// setting, as an edit would.
        @MainActor
        static func current(for reading: AppearanceThemeReadingSettings) -> Self {
            let settings = GlobalSettings.shared
            let items = reading.items
            guard let name = settings.readingImportThemeName(for: items) else { return .global }
            return items.isSubset(of: settings.readingSettingsScope.themeItems)
                ? .theme(name: name)
                : .split(themeName: name)
        }
    }

    var appearanceItems: [Item] = []
    /// Set when the import selected a theme, which changes the app's look on the spot.
    var selectedThemeName: String?
    var readingItems: [Item] = []
    var readingPlacement: ReadingPlacement?
    var notes: [String] = []

    var isEmpty: Bool { appearanceItems.isEmpty && readingItems.isEmpty }
}

extension CustomizationImportOverview {
    /// A QiReader pack: one theme carrying extras, plus its reading setup.
    @MainActor
    init(qiTheme outcome: QiThemeImportService.Outcome) {
        if let theme = outcome.theme {
            appearanceItems = Self.appearanceItems(
                of: theme,
                installedFontName: outcome.installedFontName,
                coverCount: outcome.importedCoverCount
            )
            selectedThemeName = theme.name
        }
        if let reading = outcome.reading {
            readingItems = Self.readingItems(
                in: reading,
                fontName: outcome.readerUsesInstalledFont ? outcome.installedFontName : nil
            )
            if let theme = outcome.theme {
                readingPlacement = .followsTheme(name: theme.name)
            }
        }
        notes = outcome.notes
    }

    /// One of our own appearance files: themes, and the bundle's own look.
    @MainActor
    init(appearance summary: AppearanceImportSummary, selectedTheme: AppearanceCustomTheme?) {
        if summary.themes == 1, let selectedTheme {
            appearanceItems = Self.appearanceItems(of: selectedTheme, installedFontName: nil, coverCount: 0)
        } else if summary.themes > 1 {
            appearanceItems.append(Item(
                titleKey: "主題配色",
                systemImage: "paintpalette",
                detail: String(format: localized("%d 個主題"), summary.themes)
            ))
        }
        if summary.restoredPageBackgrounds,
           !appearanceItems.contains(where: { $0.id == "頁面背景" }) {
            appearanceItems.append(Item(titleKey: "頁面背景", systemImage: "photo"))
        }
        if summary.tabIcons > 0 {
            appearanceItems.append(Item(
                titleKey: "底部 Tab",
                systemImage: "square.grid.2x2",
                detail: String(format: localized("%d 個圖示"), summary.tabIcons)
            ))
        }
        if summary.launchImages > 0 {
            appearanceItems.append(Item(
                titleKey: "啟動圖",
                systemImage: "iphone",
                detail: String(format: localized("%d 張"), summary.launchImages)
            ))
        }
        if summary.restoredReaderBackground {
            readingItems.append(Item(
                titleKey: ReadingSetupPart.background.titleKey,
                systemImage: ReadingSetupPart.background.systemImage
            ))
            readingPlacement = .global
        }
        selectedThemeName = summary.themes > 0 ? selectedTheme?.name : nil
    }

    /// A reading-settings file, which lands on whatever setup is current.
    @MainActor
    init(readingSettings plan: ReaderSettingsImportPlan, placement: ReadingPlacement) {
        readingItems = Self.readingItems(in: plan.readingSettings, fontName: nil)
        readingPlacement = readingItems.isEmpty ? nil : placement
        notes = plan.notes
    }

    // MARK: Items

    @MainActor
    private static func appearanceItems(
        of theme: AppearanceCustomTheme,
        installedFontName: String?,
        coverCount: Int
    ) -> [Item] {
        var items = [Item(titleKey: "主題配色", systemImage: "paintpalette")]
        guard let extras = theme.extras else { return items }
        if extras.pageBackgrounds?.isEmpty == false {
            items.append(Item(titleKey: "頁面背景", systemImage: "photo"))
        }
        let tabs = Set((extras.tabIcons ?? [:]).keys.compactMap { $0.split(separator: ".").first })
        if !tabs.isEmpty {
            items.append(Item(
                titleKey: "底部 Tab",
                systemImage: "square.grid.2x2",
                detail: String(format: localized("%d 個圖示"), tabs.count)
            ))
        }
        if extras.launchImageLightFileName != nil || extras.launchImageDarkFileName != nil {
            items.append(Item(titleKey: "啟動圖", systemImage: "iphone"))
        }
        let covers = coverCount > 0
            ? coverCount
            : (extras.defaultCoverLightFileNames?.count ?? 0) + (extras.defaultCoverDarkFileNames?.count ?? 0)
        if covers > 0 {
            items.append(Item(
                titleKey: "預設封面",
                systemImage: "book.closed",
                detail: String(format: localized("%d 張"), covers)
            ))
        }
        if let font = extras.globalFontPostScript, !font.isEmpty {
            items.append(Item(
                titleKey: "全局字體",
                systemImage: "f.cursive",
                detail: installedFontName ?? fontDisplayName(font)
            ))
        }
        if extras.frostedGlass != nil || extras.glassTransparency != nil
            || extras.glowIntensity != nil || extras.glassCards != nil {
            var effects: [String] = []
            if extras.frostedGlass == true { effects.append(localized("毛玻璃")) }
            if (extras.glowIntensity ?? 0) > 0 { effects.append(localized("光暈")) }
            items.append(Item(
                titleKey: "界面效果",
                systemImage: "sparkles",
                detail: effects.isEmpty ? nil : ListFormatter.localizedString(byJoining: effects)
            ))
        }
        if extras.cardBackground?.isEmpty == false {
            items.append(Item(titleKey: "卡片背景", systemImage: "rectangle.on.rectangle"))
        }
        if extras.bookshelfGridColumnCount != nil || extras.bookshelfCoverCornerRadius != nil
            || extras.forceDefaultCover != nil {
            items.append(Item(
                titleKey: "書架",
                systemImage: "books.vertical",
                detail: extras.bookshelfGridColumnCount.map { String(format: localized("%d 欄"), $0) }
            ))
        }
        if let raw = extras.readerInterface, let interface = AppearanceReaderInterface(rawValue: raw) {
            items.append(Item(
                titleKey: "閱讀界面",
                systemImage: "menubar.rectangle",
                detail: interface.localizedTitle
            ))
        }
        // Named after the 閱讀界面 › 按鈕圖示 page these land on.
        if let chromeIcons = extras.readerChromeIcons, !chromeIcons.isEmpty {
            items.append(Item(
                titleKey: "按鈕圖示",
                systemImage: "circle.grid.2x2",
                detail: String(format: localized("%d 個圖示"), chromeIcons.count)
            ))
        }
        return items
    }

    @MainActor
    private static func readingItems(
        in reading: AppearanceThemeReadingSettings,
        fontName: String?
    ) -> [Item] {
        ReadingSetupPart.parts(in: reading).map { part in
            Item(
                titleKey: part.titleKey,
                systemImage: part.systemImage,
                detail: detail(for: part, in: reading, fontName: fontName)
            )
        }
    }

    @MainActor
    private static func detail(
        for part: ReadingSetupPart,
        in reading: AppearanceThemeReadingSettings,
        fontName: String?
    ) -> String? {
        switch part {
        case .font:
            guard let font = reading.fontPostScript else { return nil }
            if font.isEmpty { return localized("系統字體") }
            return fontName ?? fontDisplayName(font)
        case .layout:
            return reading.fontSize.map {
                String(format: localized("ReaderOverlay.Format.Points"), Int($0.rounded()))
            }
        case .pageTurn:
            if reading.scrollMode == true { return localized("捲動") }
            return reading.pageTurnStyle.flatMap(PageTurnStyle.init(rawValue:)).map { localized($0.rawValue) }
        default:
            return nil
        }
    }

    @MainActor
    private static func fontDisplayName(_ postScriptName: String) -> String {
        GlobalSettings.shared.userFonts.first { $0.postScriptName == postScriptName }?.displayName
            ?? postScriptName
    }
}

// MARK: - Sheet

/// The state of one import as the 匯入完成 sheet shows it. The sheet goes up as soon as
/// the user has answered the alert, so a pack that takes a moment to install a large
/// font shows progress instead of nothing.
@MainActor
final class CustomizationImportProgress: ObservableObject, Identifiable {
    enum Phase {
        case importing
        case finished(CustomizationImportOverview)
        case failed(String)
    }

    let id = UUID()
    @Published var phase: Phase

    init(phase: Phase = .importing) {
        self.phase = phase
    }
}

struct CustomizationImportOverviewView: View {
    @ObservedObject var progress: CustomizationImportProgress
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(localized(titleKey))
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onDone) {
                            Image(systemName: "checkmark")
                        }
                        .disabled(isImporting)
                        .accessibilityLabel(localized("完成"))
                    }
                }
        }
        // Nothing is left to confirm or undo: swiping the sheet away is the same as 完成,
        // except while the import is still writing.
        .interactiveDismissDisabled(isImporting)
    }

    private var isImporting: Bool {
        if case .importing = progress.phase { return true }
        return false
    }

    private var titleKey: String {
        switch progress.phase {
        case .importing: return "匯入中"
        case .finished: return "匯入完成"
        case .failed: return "匯入失敗"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch progress.phase {
        case .importing:
            ProgressView(localized("匯入中，請稍候…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DSColor.groupedBackground)
        case .failed(let message):
            ContentUnavailableView {
                UnavailableLabel(localized("匯入失敗"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).foregroundStyle(DSColor.textSecondary)
            }
            .background(DSColor.groupedBackground)
        case .finished(let overview) where overview.isEmpty && overview.notes.isEmpty:
            ContentUnavailableView {
                UnavailableLabel(localized("這個檔案沒有可匯入的內容。"), systemImage: "doc")
            }
            .background(DSColor.groupedBackground)
        case .finished(let overview):
            overviewList(overview)
        }
    }

    private func overviewList(_ overview: CustomizationImportOverview) -> some View {
        List {
            if !overview.appearanceItems.isEmpty {
                Section {
                    ForEach(overview.appearanceItems) { itemRow($0) }
                } header: {
                    Text(localized("外觀"))
                        .foregroundStyle(DSColor.textSecondary)
                } footer: {
                    if let name = overview.selectedThemeName {
                        Text(String(format: localized("「%@」已設為目前的外觀主題。"), name))
                            .dsSectionFooter()
                    }
                }
                .interfaceSectionSurface()
            }

            if !overview.readingItems.isEmpty {
                Section {
                    ForEach(overview.readingItems) { itemRow($0) }
                } header: {
                    Text(localized("閱讀設定"))
                        .foregroundStyle(DSColor.textSecondary)
                } footer: {
                    if let placement = overview.readingPlacement {
                        Text(placementText(placement))
                            .dsSectionFooter()
                    }
                }
                .interfaceSectionSurface()
            }

            if !overview.notes.isEmpty {
                Section {
                    ForEach(overview.notes, id: \.self) { note in
                        Text(note)
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                } header: {
                    Text(localized("未完全套用"))
                        .foregroundStyle(DSColor.textSecondary)
                }
                .interfaceSectionSurface()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DSColor.groupedBackground)
    }

    private func itemRow(_ item: CustomizationImportOverview.Item) -> some View {
        LabeledContent {
            if let detail = item.detail {
                Text(detail)
                    .foregroundStyle(DSColor.textSecondary)
            }
        } label: {
            Label {
                Text(item.title)
                    .foregroundStyle(DSColor.textPrimary)
            } icon: {
                Image(systemName: item.systemImage)
                    .foregroundStyle(DSColor.accent)
                    .accessibilityHidden(true)
            }
        }
        .font(DSFont.body)
    }

    private func placementText(_ placement: CustomizationImportOverview.ReadingPlacement) -> String {
        switch placement {
        case .followsTheme(let name):
            return String(format: localized("這些設定屬於主題「%@」，選這個主題時套用，其他主題照舊。"), name)
        case .theme(let name):
            return String(format: localized("已存進主題「%@」。"), name)
        case .split(let name):
            return String(format: localized("跟隨主題的設定已存進「%@」，其餘取代了全域設定。"), name)
        case .global:
            return localized("已取代全域閱讀設定。")
        }
    }
}

#Preview("匯入完成") {
    var overview = CustomizationImportOverview()
    overview.appearanceItems = [
        .init(titleKey: "主題配色", systemImage: "paintpalette"),
        .init(titleKey: "底部 Tab", systemImage: "square.grid.2x2", detail: "4"),
        .init(titleKey: "界面效果", systemImage: "sparkles", detail: "毛玻璃、光暈"),
    ]
    overview.selectedThemeName = "山风 - 春水漾"
    overview.readingItems = [
        .init(titleKey: "排版", systemImage: "plus.magnifyingglass", detail: "17 pt"),
        .init(titleKey: "翻頁方式", systemImage: "book.pages", detail: "捲動"),
        .init(titleKey: "頁首頁尾", systemImage: "rectangle.split.3x1"),
    ]
    overview.readingPlacement = .followsTheme(name: "山风 - 春水漾")
    overview.notes = ["左右頁邊距不同，本 App 只有單一邊距，已取兩者平均。"]
    return CustomizationImportOverviewView(
        progress: CustomizationImportProgress(phase: .finished(overview)),
        onDone: {}
    )
}

#Preview("匯入中") {
    CustomizationImportOverviewView(progress: CustomizationImportProgress(), onDone: {})
}
