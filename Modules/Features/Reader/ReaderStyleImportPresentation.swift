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

    var id: String { rawValue }

    /// MainActor: `ReaderSettingsImportService` is MainActor-isolated, and the
    /// only reader is the `.fileImporter` below, which runs in `body`.
    @MainActor
    var contentTypes: [UTType] {
        switch self {
        case .readerSettings: ReaderSettingsImportService.readerSettingsContentTypes
        case .regexHighlights, .chapterTitleStyle: ReaderSettingsImportService.styleContentTypes
        }
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
                regexHighlights: plan.regexHighlights
            )
        case .chapterTitleStyle:
            return ReaderSettingsImportPlan(
                layout: nil,
                chapterTitleStyle: plan.chapterTitleStyle,
                regexHighlights: nil
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
    /// presentation across, and 閱讀設定 itself on iOS 18+. See
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
            .alert(
                localized("套用匯入的頁首頁尾？"),
                isPresented: Binding(
                    get: { pendingPlan != nil },
                    set: { if !$0 { pendingPlan = nil } }
                ),
                presenting: pendingPlan
            ) { pending in
                Button(localized("套用")) {
                    pendingPlan = nil
                    apply(pending.plan)
                }
                Button(localized("取消"), role: .cancel) { pendingPlan = nil }
            } message: { _ in
                Text(localized("這會取代目前的頁首頁尾組件、位置與正文保留空間。"))
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(localized(alert.titleKey)),
                    message: Text(alert.message),
                    dismissButton: .default(Text(localized("確定")))
                )
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

                let plan = scope.scoped(
                    try await ReaderSettingsImportService.loadReaderSettings(from: url)
                )
                guard !plan.isEmpty else {
                    throw ReaderSettingsImportError.emptyFile
                }
                guard plan.overwritesOverlayLayout else {
                    apply(plan)
                    return
                }
                pendingPlan = PendingPlan(plan: plan)
            } catch {
                alert = ReaderStyleImportAlert(
                    titleKey: "匯入失敗",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func apply(_ plan: ReaderSettingsImportPlan) {
        do {
            let summary = try ReaderSettingsImportService.apply(plan)
            onApplied(summary)
            let name = plan.name
            let message = name?.isEmpty == false
                ? String(format: localized("已匯入「%@」：%@"), name!, summary.localizedDescription)
                : summary.localizedDescription
            alert = ReaderStyleImportAlert(titleKey: "匯入成功", message: message)
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
    }
}
