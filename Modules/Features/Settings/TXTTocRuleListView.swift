import SwiftUI
import UniformTypeIdentifiers

private enum TXTTocRulePresentationRoute: Hashable {
    case add
    case importFile
    case importURL
}

/// 設定 › 閱讀 › TXT 分章規則 (FB-139): the rules a local TXT book is split into chapters
/// by. Pushed, never a sheet: its file importer needs a first-level presenter on iOS 17
/// (`Technotes/iOS17MenuModalPresentation.md`).
struct TXTTocRuleListView: View {
    @ObservedObject private var store = TXTTocRuleStore.shared
    @EnvironmentObject private var bookStore: BookStore
    @State private var editing: TXTTocRuleEditorTarget?
    @State private var showingImportFile = false
    @State private var showingImportURL = false
    @State private var importURLText = ""
    @State private var isImporting = false
    @State private var importAlert: TXTTocRuleImportAlert?
    @State private var showLegacyActionChooser = false
    @State private var legacyActionSequence = DismissalSequencedPresentation<TXTTocRulePresentationRoute>()
    @State private var pendingDeletion: TXTTocRule?

    var body: some View {
        Group {
            if store.rules.isEmpty {
                ContentUnavailableView {
                    Label(localized("沒有分章規則"), systemImage: "list.number")
                } description: {
                    Text(localized("沒有規則時，TXT 會依段落長度分段。"))
                } actions: {
                    Button(localized("新增規則")) { editing = .new(store.nextID()) }
                        .buttonStyle(.bordered)
                }
            } else {
                List {
                    Section {
                        ForEach(store.rules) { rule in
                            row(rule)
                        }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    } footer: {
                        Text(localized("每本書使用找到最多章節的已啟用規則，數量相同時取較上面的；變更會在下次開啟書籍時重新分章，閱讀位置與書籤會保留。"))
                            .dsSectionFooter()
                    }
                    .interfaceSectionSurface()
                }
                .softScrollEdges()
            }
        }
        .navigationTitle(localized("TXT 分章規則"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                addOrImportControl
                    .accessibilityLabel(localized("新增或匯入"))
                    .disabled(isImporting)
            }
            if !store.rules.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(item: $editing) { target in
            TXTTocRuleEditView(rule: target.rule, books: localTXTBooks) { saved in
                switch target {
                case .new: store.add(saved)
                case .existing: store.update(saved)
                }
            }
        }
        .sheet(isPresented: $showLegacyActionChooser, onDismiss: presentLegacyActionAfterChooserDismissal) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                DismissalSequencedActionChooser(
                    title: localized("新增或匯入"),
                    actions: [
                        DismissalSequencedAction(route: .add, title: localized("新增規則"), systemImage: "plus"),
                        DismissalSequencedAction(route: .importFile, title: localized("從檔案匯入"),
                                                 systemImage: "square.and.arrow.down"),
                        DismissalSequencedAction(route: .importURL, title: localized("從網址匯入"), systemImage: "link"),
                    ],
                    onSelect: { legacyActionSequence.select($0) }
                )
            }
        }
        .fileImporter(isPresented: $showingImportFile, allowedContentTypes: [.json, .plainText]) { result in
            importFile(result)
        }
        .alert(localized("從網址匯入"), isPresented: $showingImportURL) {
            TextField("https://", text: $importURLText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(localized("匯入")) { Task { await importURL() } }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("legado 的 TXT 目錄規則 JSON 網址"))
        }
        .alert(item: $importAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  dismissButton: .default(Text(localized("確定"))))
        }
        .confirmationDialog(
            localized("刪除這條規則？"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { rule in
            Button(localized("刪除"), role: .destructive) { store.delete(ids: [rule.id]) }
            Button(localized("取消"), role: .cancel) {}
        } message: { rule in
            Text(TXTTocRuleDefaults.displayName(of: rule))
        }
        .overlay {
            if isImporting { ProgressView(localized("匯入中，請稍候…")) }
        }
    }

    /// The shelf's own TXT files, which the editor can preview a rule on. A remote library's
    /// copy is only on this device while a reader holds it.
    private var localTXTBooks: [ReadingBook] {
        bookStore.books.filter { $0.resolvedPipelineKind == .txt && $0.remoteSource == nil }
    }

    private func row(_ rule: TXTTocRule) -> some View {
        Button {
            editing = .existing(rule)
        } label: {
            LabeledContent {
                Text(localized(rule.enable ? "已啟用" : "已停用"))
                    .foregroundStyle(DSColor.textSecondary)
            } label: {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(TXTTocRuleDefaults.displayName(of: rule))
                        .foregroundStyle(DSColor.textPrimary)
                    Text(rule.chapterRule)
                        .font(DSFont.caption.monospaced())
                        .foregroundStyle(DSColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityHint(localized("編輯規則"))
        .swipeActions(edge: .leading) {
            Button(localized(rule.enable ? "停用" : "啟用")) {
                store.setEnabled(!rule.enable, id: rule.id)
            }
            .tint(rule.enable ? DSColor.textSecondary : DSColor.accent)
        }
        .swipeActions(edge: .trailing) {
            Button(localized("刪除"), role: .destructive) { pendingDeletion = rule }
        }
        .contextMenu {
            Button(localized(rule.enable ? "停用" : "啟用"),
                   systemImage: rule.enable ? "nosign" : "checkmark.circle") {
                store.setEnabled(!rule.enable, id: rule.id)
            }
            Button(localized("刪除"), systemImage: "trash", role: .destructive) { pendingDeletion = rule }
        }
        .accessibilityActions {
            Button(localized(rule.enable ? "停用" : "啟用")) { store.setEnabled(!rule.enable, id: rule.id) }
            Button(localized("刪除")) { pendingDeletion = rule }
        }
    }

    @ViewBuilder
    private var addOrImportControl: some View {
        if MenuModalPresentationPolicy.requiresDismissalSequencedChooser {
            Button {
                legacyActionSequence.cancel()
                showLegacyActionChooser = true
            } label: {
                Image(systemName: "plus")
            }
        } else {
            Menu {
                Button(localized("新增規則"), systemImage: "plus") { editing = .new(store.nextID()) }
                Button(localized("從檔案匯入"), systemImage: "square.and.arrow.down") { showingImportFile = true }
                Button(localized("從網址匯入"), systemImage: "link") { beginURLImport() }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private func presentLegacyActionAfterChooserDismissal() {
        switch legacyActionSequence.consumeAfterDismissal() {
        case .add: editing = .new(store.nextID())
        case .importFile: showingImportFile = true
        case .importURL: beginURLImport()
        case nil: break
        }
    }

    private func beginURLImport() {
        importURLText = ""
        showingImportURL = true
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            finishImport(try store.importLegadoData(Data(contentsOf: url)))
        } catch {
            failImport(error)
        }
    }

    private func importURL() async {
        let text = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else {
            importAlert = TXTTocRuleImportAlert(title: localized("匯入失敗"), message: localized("網址無效"))
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            let (data, _) = try await URLSession.trusting.data(from: url)
            finishImport(try store.importLegadoData(data))
        } catch {
            failImport(error)
        }
    }

    private func finishImport(_ count: Int) {
        importAlert = TXTTocRuleImportAlert(title: localized("成功匯入"),
                                            message: String(format: localized("已匯入 %d 條分章規則"), count))
    }

    private func failImport(_ error: any Error) {
        AppLogger.error("TXT chapter rule import failed", error: error)
        let detail = (error as? TXTTocRuleError).map(\.localizedMessage) ?? error.localizedDescription
        importAlert = TXTTocRuleImportAlert(title: localized("匯入失敗"),
                                            message: String(format: localized("分章規則匯入失敗：%@"), detail))
    }
}

private struct TXTTocRuleImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum TXTTocRuleEditorTarget: Identifiable {
    case new(Int64)
    case existing(TXTTocRule)

    var id: Int64 {
        switch self {
        case .new(let id): id
        case .existing(let rule): rule.id
        }
    }

    var rule: TXTTocRule {
        switch self {
        case .new(let id): TXTTocRule(id: id, name: "", chapterRule: "")
        case .existing(let rule): rule
        }
    }
}

extension TXTTocRuleError {
    var localizedMessage: String {
        switch self {
        case .emptyChapterRule: localized("章節正則不可空白")
        case .invalidRegex(let field, let message):
            String(format: localized(field == .chapter ? "章節正則無效：%@" : "分卷正則無效：%@"), message)
        }
    }
}

#Preview {
    NavigationStack { TXTTocRuleListView() }
        .environmentObject(BookStore())
}
