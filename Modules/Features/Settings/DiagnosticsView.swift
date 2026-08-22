import Combine
import SwiftUI
import UIKit

/// 設定 → 診斷與回報.
///
/// The device-readable window onto `DiagnosticLog`. Everything the app logs already
/// went to `os_log`, which needs a Mac and Console.app — so in practice a user who
/// hit a bug could only ever report "it did the thing again". This screen turns that
/// into a file they can send.
///
/// Pushed page, so `.inline` title mode (docs/design.md §2.1 — only the four tab
/// roots use `.inlineLarge`).
struct DiagnosticsView: View {

    @StateObject private var model = DiagnosticsViewModel()
    @State private var searchText = ""
    @State private var severityFilter: SeverityFilter = .all
    @State private var categoryFilter: DiagnosticCategory?
    @State private var showClearConfirmation = false
    @State private var showCopiedAlert = false
    /// Fixed once per visit. `filename()` stamps the current time, so recomputing it
    /// inside `body` would hand SwiftUI a different value on every render and make
    /// the export control point at a different filename after state updates.
    @State private var exportFilename = DiagnosticReportBundle.filename()

    enum SeverityFilter: String, CaseIterable, Identifiable {
        case all
        case noticeAndUp
        case reportableOnly

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .all:            return localized("全部")
            case .noticeAndUp:    return localized("提示以上")
            case .reportableOnly: return localized("只看異常")
            }
        }

        var minimum: DiagnosticSeverity {
            switch self {
            case .all:            return .trace
            case .noticeAndUp:    return .notice
            case .reportableOnly: return .anomaly
            }
        }
    }

    // MARK: - Derived

    private var filteredEntries: [DiagnosticEntry] {
        var entries = model.entries.filter { $0.severity >= severityFilter.minimum }
        if let categoryFilter {
            entries = entries.filter { $0.category == categoryFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.message.lowercased().contains(query)
                || ($0.detail?.lowercased().contains(query) ?? false)
        }
    }

    /// Only anomalies the user has not already sent. Exporting or copying the log
    /// acknowledges everything in it, so the banner goes quiet until something new
    /// happens rather than nagging about a report already made.
    private var reportableCount: Int {
        _ = model.acknowledgementRevision
        return model.entries.filter { DiagnosticLog.shared.isUnreported($0) }.count
    }

    private var exportBundle: DiagnosticReportBundle {
        DiagnosticReportBundle(
            filename: exportFilename,
            entries: model.entries,
            session: model.session,
            uncleanSessions: model.uncleanSessions
        )
    }

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                if reportableCount > 0 {
                    DiagnosticAnomalyBanner(count: reportableCount)
                }

                ShareLink(item: exportBundle, preview: SharePreview(exportBundle.filename)) {
                    Label(
                        reportableCount > 0 ? localized("匯出並回報") : localized("匯出紀錄"),
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(
                    reportableCount > 0 ? localized("匯出並回報") : localized("匯出紀錄")
                )
                .accessibilityIdentifier("diagnostics_export_button")
            }
            .interfaceSectionSurface()

            if !model.uncleanSessions.isEmpty {
                Section {
                    ForEach(model.uncleanSessions) { session in
                        DiagnosticCrashSessionRow(session: session)
                    }
                } header: {
                    Text(localized("上次未正常結束"))
                } footer: {
                    Text(localized("App 在使用中結束，而不是被系統回收。詳細的崩潰內容會在下次啟動後由系統送達，出現在下方紀錄裡。"))
                }
                .interfaceSectionSurface()
            }

            Section {
                Picker(localized("嚴重程度"), selection: $severityFilter) {
                    ForEach(SeverityFilter.allCases) { filter in
                        Text(filter.localizedName).tag(filter)
                    }
                }
                Picker(localized("分類"), selection: $categoryFilter) {
                    Text(localized("全部")).tag(DiagnosticCategory?.none)
                    ForEach(DiagnosticCategory.allCases, id: \.self) { category in
                        Text(category.localizedName).tag(DiagnosticCategory?.some(category))
                    }
                }
                Toggle(localized("記錄詳細追蹤"), isOn: $model.isVerboseEnabled)
            } header: {
                Text(localized("篩選"))
            } footer: {
                Text(localized("詳細追蹤會記下每一次翻頁與解析步驟，適合在重現問題前打開。關閉時仍會記錄錯誤與異常。"))
            }
            .interfaceSectionSurface()

            Section {
                if model.isLoading {
                    HStack(spacing: DSSpacing.md) {
                        ProgressView()
                        Text(localized("載入中…"))
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                } else if filteredEntries.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredEntries) { entry in
                        DiagnosticEntryRow(entry: entry)
                    }
                }
            } header: {
                Text(localized("紀錄"))
            }
            .interfaceSectionSurface()
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: localized("搜尋紀錄")
        )
        .navigationTitle(localized("診斷與回報"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = exportBundle.render()
                        showCopiedAlert = true
                    } label: {
                        Label(localized("複製全部"), systemImage: "doc.on.doc")
                    }
                    Button {
                        model.reload()
                    } label: {
                        Label(localized("重新整理"), systemImage: "arrow.clockwise")
                    }
                    #if DEBUG
                    Button {
                        MetricKitDiagnosticReporter.shared.injectSampleDiagnosticForTesting()
                        // A realistic retry loop, so the escalation and its reason
                        // sequence can be seen without waiting for a source to misbehave.
                        ChapterRetryLog.resetForTesting()
                        ChapterRetryLog.record(.fetchCancelled, chapter: 42, bookId: "sample")
                        ChapterRetryLog.record(.fetchCancelled, chapter: 42, bookId: "sample")
                        ChapterRetryLog.record(.cacheInconsistent, chapter: 42, bookId: "sample")
                        model.reload()
                    } label: {
                        Label("Inject sample anomaly", systemImage: "ladybug")
                    }
                    #endif
                    Divider()
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label(localized("清除紀錄"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(localized("更多動作"))
            }
        }
        .confirmationDialog(
            localized("清除所有診斷紀錄？"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(localized("清除"), role: .destructive) { model.clear() }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("清除後無法復原。如果要回報問題，請先匯出。"))
        }
        .alert(localized("已複製"), isPresented: $showCopiedAlert) {
            Button(localized("好"), role: .cancel) {}
        } message: {
            Text(localized("診斷紀錄已複製到剪貼簿。"))
        }
        .task { model.loadIfNeeded() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(localized("沒有符合的紀錄"), systemImage: "text.magnifyingglass")
        } description: {
            Text(model.entries.isEmpty
                 ? localized("目前沒有任何診斷紀錄。繼續使用 app，有狀況時就會出現在這裡。")
                 : localized("換一個篩選條件或搜尋字詞試試。"))
        }
    }
}

/// Owns loading snapshots off the main thread.
///
/// `DiagnosticLog.snapshot()` decodes the whole on-disk log, so it must not run on
/// the main actor. Separating it into a view model also keeps `@Published` writes out
/// of view-update time — this codebase has already paid for that mistake once
/// ("Publishing changes from within view updates", see the visible-refresh ack).
@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []
    @Published private(set) var uncleanSessions: [DiagnosticSession] = []
    @Published private(set) var isLoading = false
    /// Bumped when the log is exported or copied. Nothing reads the value — publishing
    /// it is what makes `reportableCount` recompute against the new watermark.
    @Published private(set) var acknowledgementRevision = 0

    private var acknowledgementObserver: NSObjectProtocol?

    @Published var isVerboseEnabled: Bool {
        didSet {
            guard isVerboseEnabled != oldValue else { return }
            DiagnosticLog.shared.isVerboseEnabled = isVerboseEnabled
        }
    }

    let session = DiagnosticLog.shared.currentSession

    private var hasLoaded = false

    init() {
        isVerboseEnabled = DiagnosticLog.shared.isVerboseEnabled
        acknowledgementObserver = NotificationCenter.default.addObserver(
            forName: DiagnosticLog.didAcknowledgeReported,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.acknowledgementRevision += 1 }
        }
    }

    deinit {
        if let acknowledgementObserver {
            NotificationCenter.default.removeObserver(acknowledgementObserver)
        }
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let log = DiagnosticLog.shared
            let entries = log.snapshot()
            let unclean = log.uncleanPreviousSessions()
            await MainActor.run { [weak self] in
                self?.entries = entries
                self?.uncleanSessions = unclean
                self?.isLoading = false
            }
        }
    }

    func clear() {
        DiagnosticLog.shared.clear()
        entries = []
        uncleanSessions = []
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
