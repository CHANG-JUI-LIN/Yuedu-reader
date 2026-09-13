import SwiftUI
import UniformTypeIdentifiers

struct AIStatusView: View {
    let adapter: AIBookContentAdapter
    @ObservedObject private var service = AIAssistantService.shared
    @ObservedObject private var diagnostics = AIDiagnosticStore.shared
    @ObservedObject private var embedding = AIEmbeddingModelStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var includeMessages = false
    @State private var includeEvidence = false
    @State private var includeResponse = false
    @State private var document: AIDiagnosticDocument?
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent(localized("章節目錄"), value: "\(adapter.manifest.chapters.count)")
                LabeledContent(localized("本機可用正文"), value: "\(adapter.manifest.chapters.filter { $0.status == .available }.count) / \(adapter.manifest.chapters.count)")
                LabeledContent(localized("已索引章節"), value: "\(service.indexedChapterCounts[adapter.chunkBookID] ?? 0)")
                LabeledContent(localized("檢索索引"), value: indexDescription)
                LabeledContent(localized("全書人物抽取"), value: localized("尚未實作"))
                ForEach(adapter.manifest.chapters.filter { $0.status != .available }, id: \.order) { chapter in
                    LabeledContent(String(format: localized("第 %d 章"), chapter.order + 1), value: availability(chapter.status))
                }
            } footer: {
                Text(localized("未下載或抽取失敗的章節不在搜尋範圍；不會自動下載正文。提要僅涵蓋最近最多 12 個已讀片段。"))
                    .dsSectionFooter()
                Text(localized("位置使用來源 UTF-16；正文與排版不同且無法驗證時，排除當章未確認範圍並停止引用跳轉。"))
                    .dsSectionFooter()
            }
            Section {
                LabeledContent(localized("語意檢索"), value: embeddingDescription)
                if let reason = diagnostics.retrievalDegradation {
                    LabeledContent(localized("本次已降級關鍵字檢索"), value: AIEmbeddingContract.Failure(rawValue: reason)?.localizedDescription ?? localized("語意模型目前不可用"))
                }
            } footer: {
                Text(localized("契約驗證與語意品質不同；尚未評測語意品質。模型不可用時仍可使用關鍵字檢索。"))
                    .dsSectionFooter()
            }
            Section {
                Toggle(localized("下一次請求保留敏感診斷內容"), isOn: $diagnostics.captureNextRequestContent)
                Toggle(localized("匯出 messages 與讀者輸入"), isOn: $includeMessages)
                Toggle(localized("匯出檢索原文"), isOn: $includeEvidence)
                Toggle(localized("匯出模型回覆與自評"), isOn: $includeResponse)
                if let trace = diagnostics.latest, trace.bookID == adapter.chunkBookID {
                    LabeledContent(localized("診斷請求"), value: trace.requestID.uuidString)
                }
                Button(localized("匯出本機診斷")) { export() }
                    .disabled(diagnostics.latest?.bookID != adapter.chunkBookID)
                if let exportError { Text(exportError).foregroundStyle(DSColor.destructive) }
            } footer: {
                Text(localized("預設僅保存 metadata。開啟保留後，下一次請求的輸入、messages、檢索原文與回覆暫存記憶體；匯出只包含勾選內容，會遮蔽憑證、帳號與網址，不會自動上傳。"))
                    .dsSectionFooter()
            }
        }
        .navigationTitle(localized("AI 狀態與診斷"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(localized("完成")) { dismiss() } } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Yuedu-AI-diagnostics") { result in
            if case .failure = result { exportError = localized("診斷匯出失敗") }
        }
    }
    private var indexDescription: String {
        switch service.indexState[adapter.chunkBookID] ?? .idle {
        case .idle: return localized("尚未建立")
        case let .building(completed, total): return String(format: localized("建立中 %1$d / %2$d 片段"), completed, total)
        case let .ready(count, tier): return String(format: localized("已索引 %d 個片段"), count) + " · " + (tier == .keyword ? localized("關鍵字") : localized("混合檢索"))
        case let .failed(message): return message
        }
    }
    private var embeddingDescription: String {
        switch embedding.state {
        case .absent: return localized("關鍵字模式，未安裝語意模型")
        case .installed: return localized("模型已安裝，尚未驗證契約")
        case .ready: return localized("模型載入及契約驗證通過")
        case .downloading: return localized("下載中…")
        case .verifying: return localized("驗證中…")
        case let .failed(reason): return reason
        }
    }
    private func availability(_ status: AISourceManifest.Availability) -> String {
        switch status {
        case .available: return localized("正文已取得")
        case .notDownloaded: return localized("尚未下載")
        case .extractionFailed: return localized("正文抽取失敗")
        case .unsupported: return localized("格式不支援正文抽取")
        }
    }
    private func export() {
        var categories = Set<String>()
        if includeMessages { categories.insert("messages") }
        if includeEvidence { categories.insert("evidence") }
        if includeResponse { categories.formUnion(["response", "assessment"]) }
        do {
            guard let trace = diagnostics.latest, trace.bookID == adapter.chunkBookID else { return }
            document = AIDiagnosticDocument(data: try trace.export(including: categories))
            exporting = true
        } catch { exportError = localized("診斷匯出失敗") }
    }
}
struct AIDiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#Preview {
    NavigationStack { AIStatusView(adapter: .init(bookID: UUID(), chapters: [], textForChapter: { _ in nil })) }
}
