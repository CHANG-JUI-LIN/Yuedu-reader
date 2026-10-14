import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 新增來源配置

/// The three ways in: an empty source in the editor, a pasted or picked JSON, or a JSON's address.
enum BookSourceAddRoute: CaseIterable, Hashable {
    case add
    case local
    case network

    var titleKey: String {
        switch self {
        case .add: "手動新增"
        case .local: "本地導入"
        case .network: "網路導入"
        }
    }

    var systemImage: String {
        switch self {
        case .add: "square.and.pencil"
        case .local: "doc.badge.plus"
        case .network: "network"
        }
    }

    var chooserAction: DismissalSequencedAction<BookSourceAddRoute> {
        DismissalSequencedAction(route: self, title: localized(titleKey), systemImage: systemImage)
    }
}

private enum BookSourceFileImportRoute: Hashable {
    case document
}

/// 新增來源配置, one flow for 來源配置管理's 「+」 and 資源庫's ••• (Phase 5 plan, decision 31; 5h-4).
/// Moved out of `BookSourceListView` unchanged: every route parses, then waits on the
/// confirmation list, and nothing is written until the reader confirms.
///
/// Every destination is a sheet or a document picker, so the iOS 17 sequencing in
/// `Technotes/iOS17MenuModalPresentation.md` applies wherever it is opened from: a menu's choice
/// reaches `begin(_:)` only after the menu or its chooser has dismissed.
@MainActor
final class BookSourceAddFlow: ObservableObject {
    struct Message {
        let isError: Bool
        let text: String
    }

    @Published var showsChooser = false
    @Published var showsEditor = false
    @Published var showsImport = false
    @Published var showsImportFile = false
    @Published var showsFirstLevelImportFile = false
    @Published var showsNetworkImport = false
    @Published private var disclaimer = SourceDisclaimerGate<BookSourceAddRoute>()
    @Published var importJSON = ""
    @Published var importURLString = ""
    @Published var networkImportLoading = false
    @Published var message: Message?

    let store: BookSourceStore
    /// Owns the import confirmation list for every route.
    let importCoordinator: BookSourceImportCoordinator

    private var chooserSequence = DismissalSequencedPresentation<BookSourceAddRoute>()
    private var fileImportSequence = DismissalSequencedPresentation<BookSourceFileImportRoute>()
    /// Parsed sources waiting for the sheet in front of them to finish dismissing before the
    /// confirmation list can be presented.
    private var queuedImportSources: [BookSource]?

    init(store: BookSourceStore = .shared) {
        self.store = store
        importCoordinator = BookSourceImportCoordinator(store: store)
    }

    static let importContentTypes: [UTType] = [
        .json,
        .plainText,
        UTType(filenameExtension: "yds") ?? .data,
        UTType(filenameExtension: "mrs") ?? .data,
    ]

    // MARK: Opening

    /// Opens a route. 來源配置管理 asks for the source disclaimer as it opens; 資源庫 does not,
    /// so a reader who has not accepted it sees it first, and the route follows its dismissal.
    func begin(_ route: BookSourceAddRoute) {
        guard let route = disclaimer.pass(route) else { return }
        switch route {
        case .add: showsEditor = true
        case .local: showsImport = true
        case .network: showsNetworkImport = true
        }
    }

    var showsDisclaimer: Bool {
        get { disclaimer.isPresented }
        set { disclaimer.isPresented = newValue }
    }

    func acceptDisclaimer() {
        disclaimer.accept()
    }

    func afterDisclaimerDismissal() {
        disclaimer.afterDismissal().map(begin)
    }

    /// iOS 17's chooser in place of the 「+」 menu.
    func openChooser() {
        chooserSequence.cancel()
        showsChooser = true
    }

    func choose(_ route: BookSourceAddRoute) {
        chooserSequence.select(route)
    }

    func afterChooserDismissal() {
        chooserSequence.consumeAfterDismissal().map(begin)
    }

    // MARK: Local import

    func requestFileImport() {
        if BookSourceImportPresentationPolicy.requiresFirstLevelImporter {
            fileImportSequence.select(.document)
            showsImport = false
        } else {
            showsImportFile = true
        }
    }

    func cancelImport() {
        fileImportSequence.cancel()
        showsImport = false
        importJSON = ""
    }

    /// The import sheet dismisses for two different reasons — the reader picked 從文件選取, or a
    /// parsed pack is waiting for review. Only one is ever pending.
    func afterImportSheetDismissal() {
        if fileImportSequence.consumeAfterDismissal() == .document {
            showsFirstLevelImportFile = true
        }
        presentQueuedImportReview()
    }

    func handleImportFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                AppLogger.error("Book source file could not be read", error: error,
                                context: ["extension": url.pathExtension])
                fail(localized("無法讀取文件"))
                return
            }
            do {
                queueImportReview(try store.parseForImport(data: data, fileExtension: url.pathExtension))
            } catch {
                fail(error.localizedDescription)
            }
        case .failure(let error):
            fail(error.localizedDescription)
        }
    }

    func importText(_ json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            queueImportReview(try store.parseForImport(json: trimmed))
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: Network import

    func cancelNetworkImport() {
        showsNetworkImport = false
        importURLString = ""
    }

    func importFromNetwork() {
        let urlString = importURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            fail(localized("無效的 URL"))
            return
        }
        networkImportLoading = true
        Task {
            defer { networkImportLoading = false }
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(from: url)
            } catch {
                fail(error.localizedDescription)
                return
            }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                fail(localized("無法解析伺服器回應"))
                return
            }
            importURLString = ""
            // `queueImportReview` closes this sheet and sequences the review list.
            importText(text)
        }
    }

    /// 粘貼源: imports the clipboard's book-source JSON (or fetches it when the clipboard holds
    /// a URL), through the same import path as 本地導入.
    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(localized("剪貼簿為空"))
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            importURLString = trimmed
            importFromNetwork()
            return
        }
        importText(trimmed)
    }

    // MARK: Review

    /// Nothing is written until the reader confirms: every route parses, then shows the
    /// confirmation list. When a sheet is still on screen the list waits for its real
    /// `onDismiss`: presenting on the frame the previous sheet dismisses is unreliable.
    private func queueImportReview(_ sources: [BookSource]) {
        importJSON = ""
        if showsImport || showsNetworkImport {
            queuedImportSources = sources
            showsImport = false
            showsNetworkImport = false
        } else {
            importCoordinator.present(sources: sources)
        }
    }

    func presentQueuedImportReview() {
        guard let sources = queuedImportSources else { return }
        queuedImportSources = nil
        importCoordinator.present(sources: sources)
    }

    func commitImportReview() {
        do {
            let count = try importCoordinator.confirmImport()
            message = Message(isError: false, text: String(format: localized("成功匯入 %d 個來源配置"), count))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ text: String) {
        message = Message(isError: true, text: text)
    }
}

// MARK: - Presentations

extension View {
    /// The flow's sheets, pickers and outcome alert, on the screen that opens it.
    func bookSourceAddFlow(_ flow: BookSourceAddFlow) -> some View {
        modifier(BookSourceAddFlowPresentations(flow: flow, coordinator: flow.importCoordinator))
    }
}

private struct BookSourceAddFlowPresentations: ViewModifier {
    @ObservedObject var flow: BookSourceAddFlow
    @ObservedObject var coordinator: BookSourceImportCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.showsChooser, onDismiss: flow.afterChooserDismissal) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                    DismissalSequencedActionChooser(
                        title: localized("新增來源配置"),
                        actions: BookSourceAddRoute.allCases.map(\.chooserAction),
                        onSelect: flow.choose
                    )
                }
            }
            .sheet(isPresented: $flow.showsEditor) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                    BookSourceEditView(source: BookSource()) { source in
                        flow.store.add(source)
                    }
                }
            }
            .sheet(isPresented: $flow.showsImport, onDismiss: flow.afterImportSheetDismissal) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    BookSourceImportSheet(flow: flow)
                }
            }
            .fileImporter(
                isPresented: $flow.showsFirstLevelImportFile,
                allowedContentTypes: BookSourceAddFlow.importContentTypes,
                onCompletion: flow.handleImportFile
            )
            .sheet(isPresented: $flow.showsNetworkImport, onDismiss: flow.presentQueuedImportReview) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    BookSourceNetworkImportSheet(flow: flow)
                }
            }
            .sheet(item: $coordinator.pending) { _ in
                BookSourceImportReviewSheet(
                    coordinator: coordinator,
                    onConfirm: flow.commitImportReview,
                    onCancel: { coordinator.cancel() }
                )
            }
            .fullScreenCover(isPresented: $flow.showsDisclaimer, onDismiss: flow.afterDisclaimerDismissal) {
                SourceDisclaimerView { flow.acceptDisclaimer() }
            }
            .alert(
                flow.message?.isError == true ? localized("操作失敗") : localized("完成"),
                isPresented: Binding(
                    get: { flow.message != nil },
                    set: { if !$0 { flow.message = nil } }
                )
            ) {
                Button(localized("確定"), role: .cancel) {}
            } message: {
                Text(flow.message?.text ?? "")
            }
    }
}

// MARK: - Controls

/// The flow's three routes, as menu items.
struct BookSourceAddMenuItems: View {
    let flow: BookSourceAddFlow

    var body: some View {
        Button {
            flow.begin(.add)
        } label: {
            Label(localized(BookSourceAddRoute.add.titleKey), systemImage: BookSourceAddRoute.add.systemImage)
        }
        Divider()
        ForEach([BookSourceAddRoute.local, .network], id: \.self) { route in
            Button {
                flow.begin(route)
            } label: {
                Label(localized(route.titleKey), systemImage: route.systemImage)
            }
        }
    }
}

/// 來源配置管理's 「+」: a native menu from iOS 18; on iOS 17 a chooser, since every route is a
/// sheet or a document picker, which a still-dismissing menu can drop.
struct BookSourceAddToolbarControl: View {
    let flow: BookSourceAddFlow

    var body: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                flow.openChooser()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(localized("新增來源配置"))
        } else {
            Menu {
                BookSourceAddMenuItems(flow: flow)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(localized("新增來源配置"))
        }
    }
}

// MARK: - Sheets

private struct BookSourceImportSheet: View {
    @ObservedObject var flow: BookSourceAddFlow

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundColor(DSColor.accent)
                    Text(localized("貼上 Legado 格式的來源配置 JSON（支援單個 {} 或陣列 []），或選取 .json 文件。"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                TextEditor(text: $flow.importJSON)
                    .font(DSFont.fixed(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .frame(maxHeight: 280)

                Button {
                    flow.requestFileImport()
                } label: {
                    Label(localized("從文件選取 .json"), systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                Spacer()
            }
            .navigationTitle(localized("匯入來源配置"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        flow.cancelImport()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        flow.importText(flow.importJSON)
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("匯入"))
                    .disabled(flow.importJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .fileImporter(
            isPresented: $flow.showsImportFile,
            allowedContentTypes: BookSourceAddFlow.importContentTypes,
            onCompletion: flow.handleImportFile
        )
    }
}

private struct BookSourceNetworkImportSheet: View {
    @ObservedObject var flow: BookSourceAddFlow

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network").foregroundColor(DSColor.accent)
                    Text(localized("輸入來源配置 JSON 的網路地址，支援直接返回 JSON 的 URL。"))
                        .font(DSFont.caption).foregroundColor(DSColor.textSecondary)
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                TextField("https://example.com/booksource.json", text: $flow.importURLString)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal)

                if flow.networkImportLoading {
                    ProgressView()
                        .padding(.top, 24)
                }

                Spacer()
            }
            .navigationTitle(localized("網路導入"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .settings)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        flow.cancelNetworkImport()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        flow.importFromNetwork()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(localized("匯入"))
                    .disabled(
                        flow.importURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || flow.networkImportLoading)
                }
            }
        }
    }
}

#if DEBUG
#Preview("網路導入") {
    BookSourceNetworkImportSheet(flow: BookSourceAddFlow())
}

#Preview("匯入來源配置") {
    BookSourceImportSheet(flow: BookSourceAddFlow())
}
#endif
