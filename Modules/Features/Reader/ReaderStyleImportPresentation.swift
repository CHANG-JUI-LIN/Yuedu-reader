import SwiftUI
import UniformTypeIdentifiers

/// What a 匯入 control on 閱讀設定 or one of its sub-pages asked for.
enum ReaderStyleImportRoute: String, Identifiable, Sendable {
    /// 匯入閱讀設定 — the whole bundle, or the legado `readConfig.json` / `.zip`
    /// the app has always accepted.
    case readerSettings
    /// The 正則高亮 page's own 匯入 — applies only the rules, even if the picked
    /// file happens to carry more.
    case regexHighlights
    /// The 章節標題樣式 page's own 匯入.
    case chapterTitleStyle
    /// The 對話氣泡 page's own 匯入 — accepts the script-based bubble files and
    /// keeps only their settings.
    case dialogueBubble
    /// 氣泡設定's 段評氣泡 page: a bubble SVG or `bubble.json`.
    case commentBubble
    /// 氣泡設定's 本章說 / 作者說 / 神評論 pages: a card template, bare or packaged.
    case chapterSayCard
    case authorSayCard
    case hotCommentCard
    /// 字體's 匯入字體…: a font file, made the reader's font. It shares this picker because
    /// SwiftUI presents only one of two `.fileImporter`s on a view: a font importer of its
    /// own beside this one never opened (feedback #61).
    case readerFont

    var id: String { rawValue }

    /// The 氣泡設定 page this route imports for, or nil for a reading-settings file.
    var commentStyleTarget: ReaderCommentStyleImporter.Target? {
        switch self {
        case .readerSettings, .regexHighlights, .chapterTitleStyle, .dialogueBubble, .readerFont: nil
        case .commentBubble: .bubble
        case .chapterSayCard: .card(.chapterSay)
        case .authorSayCard: .card(.authorSay)
        case .hotCommentCard: .card(.hotComment)
        }
    }

    static func commentCard(_ kind: ReaderCommentCardKind) -> ReaderStyleImportRoute {
        switch kind {
        case .chapterSay: .chapterSayCard
        case .authorSay: .authorSayCard
        case .hotComment: .hotCommentCard
        }
    }

    /// MainActor: `ReaderSettingsImportService` is MainActor-isolated, and the
    /// only reader is the `.fileImporter` below, which runs in `body`.
    @MainActor
    var contentTypes: [UTType] {
        switch self {
        case .readerSettings: ReaderSettingsImportService.readerSettingsContentTypes
        case .regexHighlights, .chapterTitleStyle, .dialogueBubble:
            ReaderSettingsImportService.styleContentTypes
        case .commentBubble, .chapterSayCard, .authorSayCard, .hotCommentCard:
            ReaderCommentStyleImporter.contentTypes
        case .readerFont:
            [.font, UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data]
        }
    }

    /// The title of the alert a failed import shows.
    var failureTitleKey: String {
        self == .readerFont ? "字體匯入失敗" : "匯入失敗"
    }

    /// Narrows a parsed file to what this entry point promised to change. 匯入
    /// on the 正則高亮 page must not quietly resize the user's type because the
    /// file also contained layout parameters.
    func scoped(_ plan: ReaderSettingsImportPlan) -> ReaderSettingsImportPlan {
        switch self {
        case .readerSettings:
            return plan
        case .regexHighlights:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: nil,
                regexHighlights: plan.regexHighlights,
                dialogueBubbleStyle: nil,
                contentName: plan.contentName,
                notes: plan.notes
            )
        case .chapterTitleStyle:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: plan.chapterTitleStyle,
                regexHighlights: nil,
                dialogueBubbleStyle: nil,
                contentName: plan.contentName,
                notes: plan.notes
            )
        case .dialogueBubble:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: nil,
                regexHighlights: nil,
                dialogueBubbleStyle: plan.dialogueBubbleStyle,
                contentName: plan.contentName,
                notes: plan.notes
            )
        case .commentBubble, .chapterSayCard, .authorSayCard, .hotCommentCard, .readerFont:
            // These files are not reading settings; `ReaderCommentStyleImporter` and
            // `GlobalSettings.importReaderFont` read them and nothing of a reading-settings
            // plan applies.
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: nil,
                regexHighlights: nil,
                dialogueBubbleStyle: nil,
                contentName: plan.contentName,
                notes: plan.notes
            )
        }
    }
}

struct ReaderStyleImportAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let message: String
}

extension View {
    /// Presents the document picker for `route`, applies what it returns, and
    /// reports the result.
    ///
    /// Attached by whoever owns the **first-level** presenter: `ReaderView` on
    /// iOS 17, where 閱讀設定 is a presented sheet that iOS 17 can drop a picker
    /// presentation across, and 閱讀設定 itself on iOS 18+. It is the only
    /// `.fileImporter` either one attaches: SwiftUI presents one of two on a view. See
    /// `Technotes/iOS17MenuModalPresentation.md`.
    func readerStyleImportPresentation(
        route: Binding<ReaderStyleImportRoute?>,
        onApplied: @escaping (ReaderSettingsImportSummary) -> Void = { _ in }
    ) -> some View {
        modifier(ReaderStyleImportPresentationModifier(route: route, onApplied: onApplied))
    }
}

private struct ReaderStyleImportPresentationModifier: ViewModifier {
    @Binding var route: ReaderStyleImportRoute?
    let onApplied: (ReaderSettingsImportSummary) -> Void

    /// Mirrors `route` for the duration of the picker. `onCompletion` and the
    /// `isPresented` reset are two separate SwiftUI updates with no defined
    /// order, so the handler cannot rely on `route` still being set.
    @State private var activeRoute: ReaderStyleImportRoute?
    @State private var pendingPlan: PendingPlan?
    @State private var alert: ReaderStyleImportAlert?
    /// The 匯入完成 sheet: what the file changed and where it landed.
    @State private var importProgress: CustomizationImportProgress?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: Binding(
                    get: { route != nil },
                    set: { if !$0 { route = nil } }
                ),
                allowedContentTypes: (route ?? .readerSettings).contentTypes,
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .onChanged(of: route) { newValue in
                if let newValue { activeRoute = newValue }
            }
            .customizationImportPrompt($pendingPlan, prompt: \.prompt) { pending in
                apply(pending.plan)
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(localized(alert.titleKey)),
                    message: Text(alert.message),
                    dismissButton: .default(Text(localized("確定")))
                )
            }
            .sheet(item: $importProgress) { progress in
                CustomizationImportOverviewView(progress: progress) {
                    importProgress = nil
                }
            }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let scope = activeRoute ?? .readerSettings
        activeRoute = nil
        Task { @MainActor in
            do {
                guard let url = try result.get().first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                if scope == .readerFont {
                    // The new font is selected; the 字體 row and the preview show it.
                    try GlobalSettings.shared.importReaderFont(from: url)
                    return
                }
                if let target = scope.commentStyleTarget {
                    let message = try ReaderCommentStyleImporter.importFile(at: url, into: target)
                    alert = ReaderStyleImportAlert(titleKey: "SVG 匯入成功", message: message)
                    return
                }

                let plan = scope.scoped(
                    try await ReaderSettingsImportService.loadReaderSettings(from: url)
                )
                guard !plan.isEmpty else {
                    throw ReaderSettingsImportError.emptyFile
                }
                // A layout replaces the whole reading setup — type, spacing, margins,
                // page turn, header/footer — so it is confirmed first, in words that say
                // so. A page's own 匯入 (章節標題、正則高亮、對話氣泡) never carries one and
                // changes only what that page is about.
                guard plan.layout != nil else {
                    apply(plan)
                    return
                }
                pendingPlan = PendingPlan(
                    plan: plan,
                    prompt: .readingSettings(
                        named: plan.name,
                        parts: ReadingSetupPart.parts(in: plan.readingSettings),
                        themeName: GlobalSettings.shared.readingImportThemeName(for: plan.readingSettings.items)
                    )
                )
            } catch {
                alert = ReaderStyleImportAlert(
                    titleKey: scope.failureTitleKey,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func apply(_ plan: ReaderSettingsImportPlan) {
        do {
            let summary = try ReaderSettingsImportService.apply(plan)
            onApplied(summary)
            // The import lands like an edit: on the worn theme for what follows the
            // theme, in 全域 for the rest. The sheet says which, and lists what a converted
            // file lost —
            // silence would leave the user comparing the result against the original
            // with no idea which differences are ours.
            importProgress = CustomizationImportProgress(phase: .finished(
                CustomizationImportOverview(readingSettings: plan, placement: .current(for: plan.readingSettings))
            ))
        } catch {
            alert = ReaderStyleImportAlert(
                titleKey: "匯入失敗",
                message: error.localizedDescription
            )
        }
    }

    private struct PendingPlan: Identifiable {
        let id = UUID()
        let plan: ReaderSettingsImportPlan
        let prompt: CustomizationImportPrompt
    }
}
