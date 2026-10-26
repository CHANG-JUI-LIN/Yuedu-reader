import SwiftUI

/// AI 推薦's row on the Explore home (AI 推薦 plan 8c).
///
/// It draws the stored list itself, through `AIRecommendationProvider.entries(from:)`, so a
/// new list or an Open Library cover shows in place. Before the first list it offers 產生推薦;
/// the app never asks the reader's AI service by itself (maintainer, 2026-10-15). 重新產生 is
/// in a visible ••• beside the name, with the section's own edits (maintainer, by option).
struct AIRecommendationRow: View {
    let section: HomeSection
    /// Its name: the one the reader gave it, else 「AI 推薦」.
    let title: String
    /// The section's edits; none in the editor's preview.
    var actions: HomeSectionActions?
    let open: (HomeCardContent, [HomeCardContent]) -> Void
    /// False in the editor's preview, which must never spend the reader's quota.
    var canGenerate = true

    @EnvironmentObject private var shelf: BookStore
    @ObservedObject private var recommendations: AIRecommendationStore
    @ObservedObject private var service: AIRecommendationService
    @ObservedObject private var subscription = SubscriptionStore.shared
    @State private var showsPaywall = false
    @State private var showsMoreChooser = false
    @State private var moreSequence = DismissalSequencedPresentation<MoreAction>()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    /// 色帶書架's colour, its first cover's, once that cover has drawn.
    @State private var bandCover: CoverTint.RGB?

    /// - Parameter service: the shared one; a preview passes its own, with its own store.
    init(section: HomeSection, title: String, actions: HomeSectionActions? = nil, canGenerate: Bool = true,
         service: AIRecommendationService? = nil, open: @escaping (HomeCardContent, [HomeCardContent]) -> Void) {
        self.section = section
        self.title = title
        self.actions = actions
        self.canGenerate = canGenerate
        self.open = open
        let service = service ?? .shared
        _service = ObservedObject(wrappedValue: service)
        _recommendations = ObservedObject(wrappedValue: service.store)
    }

    private var rowID: String { section.id.uuidString }

    private enum MoreAction: Hashable {
        case regenerate
        case layout(HomeLayoutStyle)
        case hide, settings, delete
    }

    private var allowsAI: Bool {
        ReaderPremiumVisibilityPolicy(isProActive: subscription.isProActive).allowsAI
    }

    private var list: AIRecommendationList? { recommendations.list }

    private var cards: [HomeCardContent] {
        guard let list else { return [] }
        return Self.cards(for: list, store: shelf)
    }

    /// The stored works as cards, each carrying its reason into 作品詳情 (AI 推薦 8e).
    static func cards(for list: AIRecommendationList, store: BookStore) -> [HomeCardContent] {
        let reasons = AIRecommendationProvider.reasons(from: list)
        return HomeRowContent(entries: AIRecommendationProvider.entries(from: list), store: store).cards
            .map { $0.recommended(because: reasons[$0.id]) }
    }

    /// The line the reader wrote, then where the works came from and when (AI 推薦 plan: marked
    /// 「AI 產生」), which the reader's line never replaces.
    private var subtitle: String? {
        let generated = allowsAI ? list.map {
            String(format: localized("AI 產生 · %@ · %@"), $0.service, $0.generatedAt.formatted(date: .abbreviated, time: .omitted))
        } : nil
        let lines = [section.subtitle.isEmpty ? nil : section.subtitle, generated].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The list whose missing covers are filled once the row shows (feedback #10); none in the
    /// editor's preview, or without Pro, where no card is drawn.
    private var coverFillList: Date? {
        canGenerate && allowsAI ? list?.generatedAt : nil
    }

    private var canRegenerate: Bool {
        canGenerate && allowsAI && list != nil && !service.state.isRunning
    }

    /// 色帶書架 draws its band under the header and the list while the list shows alone; a status
    /// (產生中, a failure) draws the row without it, so its text keeps the page's colours.
    private var drawsBand: Bool {
        guard section.layout.drawnStyle(accessibilityTextSize: dynamicTypeSize.isAccessibilitySize) == .band,
              allowsAI, !cards.isEmpty, case .idle = service.state else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: drawsBand ? DSSpacing.lg : DSSpacing.md) {
            header
            status
            if allowsAI, !cards.isEmpty {
                HomeSectionCards(layout: section.layout, cards: cards, rowID: rowID, hasShowAll: false, open: open,
                                 bandCover: $bandCover)
            }
        }
        .modifier(HomeBandGround(cover: bandCover, isActive: drawsBand))
        .sheet(isPresented: $showsPaywall) {
            PaywallView(highlightedFeature: .aiReading)
                .environmentObject(subscription)
        }
        .task(id: coverFillList) {
            // A list saved before its covers were filled; the service asks each work once.
            guard coverFillList != nil else { return }
            await service.fillMissingCovers()
        }
    }

    private func generate() {
        service.generate(shelf: shelf)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            HomeRowTitle(title: title, subtitle: subtitle, bandLine: drawsBand ? HomeBandGround.line(for: bandCover).color : nil)
                // The band's white name on the band's colour when its long press lifts it out.
                .background(drawsBand ? HomeBandGround.ground(for: bandCover, contrast: contrast) : .clear)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.row.header.\(rowID)")
                .contextMenu { menuItems }
            Spacer(minLength: DSSpacing.sm)
            if actions != nil || canRegenerate {
                moreControl
            }
        }
        .padding(.leading, DSSpacing.lg)
        .padding(.trailing, DSSpacing.xs)
    }

    /// The ••• and the name's long press offer the same.
    @ViewBuilder
    private var menuItems: some View {
        if canGenerate, allowsAI, list != nil {
            Button(localized("重新產生"), systemImage: "arrow.clockwise", action: generate)
                .disabled(!canRegenerate)
        }
        if let actions {
            Section { HomeSectionActionsMenu(section: section, actions: actions) }
        }
    }

    /// A native menu from iOS 18; on iOS 17 a chooser sheet, since 刪除's confirmation would be
    /// dropped while the menu dismisses (`Technotes/iOS17MenuModalPresentation.md`).
    @ViewBuilder
    private var moreControl: some View {
        let label = Image(systemName: "ellipsis")
            .font(DSFont.body.weight(.semibold))
            .foregroundStyle(drawsBand ? DSColor.textOnFixedFill : DSColor.textSecondary)
            .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                moreSequence.cancel()
                showsMoreChooser = true
            } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("更多"))
                .accessibilityIdentifier("home.row.more.\(rowID)")
                .sheet(isPresented: $showsMoreChooser, onDismiss: {
                    moreSequence.consumeAfterDismissal().map(perform)
                }) {
                    AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                        DismissalSequencedActionChooser(title: title, actions: moreChoices,
                                                        onSelect: { moreSequence.select($0) })
                    }
                }
        } else {
            Menu { menuItems } label: { label }
                .accessibilityLabel(localized("更多"))
                .accessibilityIdentifier("home.row.more.\(rowID)")
        }
    }

    private var moreChoices: [DismissalSequencedAction<MoreAction>] {
        var choices: [DismissalSequencedAction<MoreAction>] = []
        if canGenerate, allowsAI, list != nil {
            choices.append(DismissalSequencedAction(route: .regenerate, title: localized("重新產生"),
                                                    systemImage: "arrow.clockwise", isEnabled: canRegenerate))
        }
        guard actions != nil else { return choices }
        let layout = section.layout
        let styles = HomeLayoutStyle.choices(for: section.binding)
        if styles.count > 1 {
            choices += styles.map { style in
                let isSelected = style == layout.style
                return DismissalSequencedAction(
                    route: .layout(style), title: localized(style.titleKey),
                    systemImage: isSelected ? "checkmark" : style.symbol,
                    // The menu's check mark, said in words: the chooser's rows have no selected state.
                    subtitle: isSelected ? [localized("呈現方式"), localized("使用中")].joined(separator: " · ") : localized("呈現方式"))
            }
        }
        choices += [
            DismissalSequencedAction(route: .hide, title: localized("動作：隱藏"), systemImage: "eye.slash"),
            DismissalSequencedAction(route: .settings, title: localized("設定"), systemImage: "slider.horizontal.3"),
            DismissalSequencedAction(route: .delete, title: localized("刪除"), systemImage: "trash", isDestructive: true),
        ]
        return choices
    }

    private func perform(_ action: MoreAction) {
        switch action {
        case .regenerate: generate()
        case .layout(let style): actions?.setLayout(HomeSectionLayout(style: style, ranked: section.layout.showsRanks))
        case .hide: actions?.hide()
        case .settings: actions?.openSettings()
        case .delete: actions?.delete()
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        if !allowsAI {
            message(localized("需要 Pro"), systemImage: "lock.fill") {
                Button(localized("升級")) { showsPaywall = true }
                    .buttonStyle(.onAccentProminent)
                    .accessibilityIdentifier("home.ai.upgrade")
            }
        } else {
            switch service.state {
            case .generating:
                progress(localized("正在產生推薦…"))
            case .resolving(let completed, let total):
                progress(String(format: localized("正在查詢封面與簡介（%d/%d）"), completed, total))
            case .failed(let reason):
                message(reason, systemImage: "exclamationmark.triangle") {
                    if case .failure = service.service() {
                        settingsLink
                    } else {
                        Button(localized("重試"), action: generate)
                            .buttonStyle(.bordered)
                            .disabled(!canGenerate)
                            .accessibilityIdentifier("home.ai.retry")
                    }
                }
            case .idle:
                if list == nil { start }
            }
        }
    }

    @ViewBuilder
    private var start: some View {
        switch service.service() {
        case .success:
            message(localized("依你最近讀的 30 本書推薦作品；會把書名、作者和分類送到你設定的 AI 服務。"), systemImage: nil) {
                Button(localized("產生推薦"), action: generate)
                    .buttonStyle(.onAccentProminent)
                    .disabled(!canGenerate)
                    .accessibilityIdentifier("home.ai.generate")
            }
        case .failure(let reason):
            message(reason.message, systemImage: nil) { settingsLink }
        }
    }

    private var settingsLink: some View {
        NavigationLink(localized("AI 助手設定")) { AISettingsView(embedded: true) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("home.ai.settings")
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView()
            Text(text)
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .padding(.horizontal, DSSpacing.lg)
    }

    private func message<Actions: View>(_ text: String, systemImage: String?, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Group {
                if let systemImage {
                    Label(text, systemImage: systemImage)
                } else {
                    Text(text)
                }
            }
            .font(DSFont.footnote)
            .foregroundStyle(DSColor.textSecondary)
            actions()
        }
        .padding(.horizontal, DSSpacing.lg)
    }
}

#Preview("尚未產生") {
    NavigationStack {
        ScrollView {
            AIRecommendationRow(section: HomeSection(layout: .row, binding: .aiRecommendations), title: localized("AI 推薦"),
                                service: AIRecommendationRowPreview.service(list: nil), open: { _, _ in })
        }
    }
    .environmentObject(BookStore())
}

#Preview("已產生，五種版面") {
    NavigationStack {
        ScrollView {
            VStack(spacing: DSSpacing.xxl) {
                ForEach(HomeLayoutStyle.choices(for: .aiRecommendations)) { style in
                    AIRecommendationRow(section: HomeSection(layout: HomeSectionLayout(style: style, ranked: false),
                                                             binding: .aiRecommendations),
                                        title: localized(style.titleKey),
                                        service: AIRecommendationRowPreview.service(list: AIRecommendationRowPreview.list),
                                        open: { _, _ in })
                }
            }
        }
    }
    .environmentObject(BookStore())
}

/// Stores of their own, so a preview never reads or writes the reader's list.
@MainActor
enum AIRecommendationRowPreview {
    static let list = AIRecommendationList(
        entries: [("球狀閃電", "劉慈欣"), ("銀河帝國：基地", "艾西莫夫"), ("沙丘", "法蘭克・赫伯特"), ("十二國記", "小野不由美")]
            .map { .init(work: .init(title: $0.0, author: $0.1, reason: "")) },
        generatedAt: Date(), service: "DeepSeek", model: "deepseek-chat")

    static func service(list: AIRecommendationList?) -> AIRecommendationService {
        let store = AIRecommendationStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("AIRecommendationRowPreview-\(UUID().uuidString)", isDirectory: true))
        if let list { store.save(list) }
        return AIRecommendationService(store: store, activeService: { .failure(.notConfigured) }, lookupEnabled: { false },
                                       coverProviders: { [] })
    }
}
