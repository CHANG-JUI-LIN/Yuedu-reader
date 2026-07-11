import SwiftUI
import UniformTypeIdentifiers

struct LegadoMigrationView: View {

    @StateObject private var manager = LegadoMigrationManager.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bookStore: BookStore

    @State private var showFilePicker = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
                Form {
                    descriptionSection
                    importSection
                    if let result = manager.importResult {
                        resultSection(result)
                    }
                    if !manager.statusLog.isEmpty {
                        logSection
                    }
                }
            .navigationTitle(localized("Legado 資料遷移"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.json, UTType(filenameExtension: "txt") ?? .plainText]
            ) { result in
                switch result {
                case .success(let url):
                    Task {
                        guard url.startAccessingSecurityScopedResource() else {
                            manager.appendLog("Failed to obtain file access permission")
                            return
                        }
                        defer { url.stopAccessingSecurityScopedResource() }
                        guard let data = try? Data(contentsOf: url) else {
                            manager.appendLog("Failed to read file content")
                            return
                        }
                        await manager.importFromJSON(data: data, bookStore: bookStore)
                    }
                case .failure(let error):
                    manager.appendLog("File selection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Sections

    private var descriptionSection: some View {
        Section(header: Text(localized("說明"))) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localized("支援從 Legado（閱讀）Android 應用匯入："))
                    .font(DSFont.subheadline)
                    .foregroundColor(DSColor.textPrimary)
                Text("• " + localized("書源 JSON（書源備份 / 分享檔）"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                Text("• " + localized("書籍 JSON（書架備份檔）"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                Text(localized("請從 Legado → 備份與恢復 中匯出對應 JSON 檔案後選擇匯入。"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
    }

    private var importSection: some View {
        Section(header: Text(localized("匯入"))) {
            Button {
                showFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .foregroundColor(DSColor.accent)
                    Text(localized("選擇 JSON 檔案"))
                        .foregroundColor(DSColor.accent)
                }
            }
            .disabled(manager.isImporting)

            if manager.isImporting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: manager.progress)
                        .tint(DSColor.accent)
                    Text(localized("匯入中，請稍候…"))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ result: LegadoMigrationManager.ImportResult) -> some View {
        Section(header: Text(localized("結果"))) {
            if result.sourcesImported > 0 {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(localized("書源：") + "\(result.sourcesImported) " + localized("個"))
                }
            }
            if result.booksImported > 0 {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(localized("書籍：") + "\(result.booksImported) " + localized("本"))
                }
            }
            if result.sourcesImported == 0 && result.booksImported == 0 && result.errors.isEmpty {
                Text(localized("未匯入任何資料"))
                    .foregroundColor(DSColor.textSecondary)
            }
            ForEach(result.errors, id: \.self) { error in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(DSFont.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var logSection: some View {
        Section(header: Text(localized("記錄"))) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(
                            Array(manager.statusLog.suffix(20).enumerated()),
                            id: \.offset
                        ) { index, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(DSColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 200)
                .onChange(of: manager.statusLog.count) { _, count in
                    let lastIndex = min(count, 20) - 1
                    if lastIndex >= 0 {
                        withAnimation { proxy.scrollTo(lastIndex, anchor: .bottom) }
                    }
                }
            }
        }
    }
}
