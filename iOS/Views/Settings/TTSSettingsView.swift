import SwiftUI
import UniformTypeIdentifiers

struct TTSSettingsView: View {
    @ObservedObject private var gs = GlobalSettings.shared
    @StateObject private var testCoordinator = TTSCoordinator()
    @State private var sourceListURL = ""
    @State private var sourceImportMessage: String?
    @State private var isImportingSources = false
    @State private var showSourceFileImporter = false
    private let localTestTemplate = "http://192.168.1.16:5001/tts?text={{text}}&rate={{speakSpeed}}"

    var body: some View {
        Form {
            Section(header: Text(localized("語音源 JSON"))) {
                TextField(localized("語音源 JSON URL"), text: $sourceListURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button {
                    Task { await importTTSSources() }
                } label: {
                    if isImportingSources {
                        Label(localized("載入中…"), systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label(localized("載入語音源 JSON"), systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(sourceListURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingSources)

                Button {
                    showSourceFileImporter = true
                } label: {
                    Label(localized("從檔案匯入語音源 JSON"), systemImage: "doc.badge.plus")
                }
                .disabled(isImportingSources)

                Text(localized("支援 Legado（閱讀）語音源 JSON。選中語音源後會寫入下方 URL 模板。"))
                    .font(.caption)
                    .foregroundColor(DSColor.textSecondary)

                if let sourceImportMessage {
                    Text(sourceImportMessage)
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                }

                if !gs.importedTTSSources.isEmpty {
                    ForEach(gs.importedTTSSources) { source in
                        Button {
                            gs.httpTtsUrlTemplate = source.urlTemplate
                            gs.httpTtsHeaders = source.headers
                        } label: {
                            HStack(spacing: 10) {
                                Text(source.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if gs.httpTtsUrlTemplate == source.urlTemplate {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }

                    Button(role: .destructive) {
                        gs.importedTTSSources = []
                        gs.httpTtsHeaders = [:]
                    } label: {
                        Text(localized("清除已匯入語音源"))
                    }
                }
            }

            Section(header: Text(localized("語音源 URL 模板"))) {
                TextEditor(text: $gs.httpTtsUrlTemplate)
                    .frame(minHeight: 80)
                    .font(.system(.footnote, design: .monospaced))

                Button {
                    gs.httpTtsUrlTemplate = localTestTemplate
                } label: {
                    Label(localized("使用本機測試服務"), systemImage: "network")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("目前沒有內建雲端 TTS。這裡需要填入能直接回傳音訊資料的接口。"))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                        .padding(.bottom, 4)
                    Text(localized("支援的佔位符："))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                    placeholderRow("{{text}}", desc: localized("段落文字（URL 編碼）"))
                    placeholderRow("{{speakText}}", desc: localized("Legado 語音源段落文字"))
                    placeholderRow("{{title}}", desc: localized("章節標題（URL 編碼）"))
                    placeholderRow("{{speakSpeed}}", desc: localized("語速，例如 +0%、+30%、-20%"))
                }
                .padding(.vertical, 4)

                HStack(spacing: 36) {
                    Spacer()
                    Button {
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                    }
                    .disabled(true)

                    Button {
                        toggleTestPlayback()
                    } label: {
                        Image(systemName: testCoordinator.playbackState == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 46))
                    }
                    .disabled(gs.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                    }
                    .disabled(true)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
                .padding(.vertical, 6)
            }
        }
        .navigationTitle(localized("語音朗讀設定"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showSourceFileImporter,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleSourceFileImport(result)
        }
        .onDisappear {
            testCoordinator.stop()
        }
    }

    // MARK: - Private

    private func placeholderRow(_ placeholder: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(placeholder)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(DSColor.accent)
            Text("—")
                .font(.caption)
                .foregroundColor(DSColor.textSecondary)
            Text(desc)
                .font(.caption)
                .foregroundColor(DSColor.textSecondary)
        }
    }

    private func toggleTestPlayback() {
        switch testCoordinator.playbackState {
        case .playing:
            testCoordinator.pause()
        case .paused:
            testCoordinator.resume()
        case .stopped:
            testCoordinator.stop(reason: "restart test playback")
            testCoordinator.speak(text: "這是一段測試文字，用於確認 HTTP TTS 引擎設定是否正確。", title: "測試")
        }
    }

    @MainActor
    private func importTTSSources() async {
        let trimmed = sourceListURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            sourceImportMessage = localized("語音源 JSON URL 無效")
            return
        }

        isImportingSources = true
        sourceImportMessage = nil
        defer { isImportingSources = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                sourceImportMessage = String(format: localized("載入失敗：HTTP %d"), http.statusCode)
                return
            }
            let imported = try TTSSourceJSONParser.parse(data: data)
            gs.importedTTSSources = mergeSources(existing: gs.importedTTSSources, imported: imported)
            sourceImportMessage = String(format: localized("已載入 %d 個語音源"), imported.count)
        } catch {
            sourceImportMessage = String(format: localized("載入失敗：%@"), error.localizedDescription)
        }
    }

    private func handleSourceFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importTTSSources(from: url) }
        case .failure(let error):
            sourceImportMessage = String(format: localized("載入失敗：%@"), error.localizedDescription)
        }
    }

    @MainActor
    private func importTTSSources(from fileURL: URL) async {
        isImportingSources = true
        sourceImportMessage = nil
        defer { isImportingSources = false }

        let hasAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let imported = try TTSSourceJSONParser.parse(data: data)
            gs.importedTTSSources = mergeSources(existing: gs.importedTTSSources, imported: imported)
            sourceImportMessage = String(format: localized("已載入 %d 個語音源"), imported.count)
        } catch {
            sourceImportMessage = String(format: localized("無法讀取語音源檔案：%@"), error.localizedDescription)
        }
    }

    private func mergeSources(existing: [ImportedTTSSource], imported: [ImportedTTSSource]) -> [ImportedTTSSource] {
        var merged = existing
        var existingURLs = Set(existing.map(\.urlTemplate))
        for source in imported where !existingURLs.contains(source.urlTemplate) {
            merged.append(source)
            existingURLs.insert(source.urlTemplate)
        }
        return merged.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
