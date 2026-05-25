import SwiftUI
import UniformTypeIdentifiers

struct TTSSettingsView: View {
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var testCoordinator = TTSCoordinator()
    @State private var sourceListURL = ""
    @State private var sourceImportMessage: String?
    @State private var isImportingSources = false
    @State private var showSourceFileImporter = false
    @State private var showNetworkImport = false
    @State private var searchText = ""

    private var filteredSources: [ImportedTTSSource] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return gs.importedTTSSources }
        return gs.importedTTSSources.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.urlTemplate.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationView {
            AdaptiveSheetContainer(maxWidth: 980) {
                VStack(spacing: 0) {
                    searchBar

                    Divider()

                    if gs.importedTTSSources.isEmpty {
                        emptyView
                    } else {
                        sourceList
                    }

                    Divider()

                    bottomToolbar
                }
            }
            .navigationTitle(localized("語音朗讀設定"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("關閉")) { dismissSettings() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showSourceFileImporter = true
                        } label: {
                            Label(localized("本地導入"), systemImage: "doc.badge.plus")
                        }
                        Button {
                            showNetworkImport = true
                        } label: {
                            Label(localized("網路導入"), systemImage: "network")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(isImportingSources)
                }
            }
            .sheet(isPresented: $showNetworkImport) {
                AdaptiveSheetContainer(maxWidth: 820) {
                    networkImportSheet
                }
            }
            .overlay(alignment: .top) {
                if let sourceImportMessage {
                    toastBanner(sourceImportMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation { self.sourceImportMessage = nil }
                            }
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
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

    private var searchBar: some View {
        DSSearchBar(placeholder: localized("搜索語音源"), text: $searchText)
    }

    private var sourceList: some View {
        List {
            ForEach(filteredSources) { source in
                sourceRow(source)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
    }

    private func sourceRow(_ source: ImportedTTSSource) -> some View {
        HStack(spacing: 0) {
            Button {
                selectSource(source)
            } label: {
                Image(systemName: isSelected(source) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected(source) ? DSColor.accent : Color(UIColor.systemGray3))
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.trailing, 12)

            Button {
                selectSource(source)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .font(DSFont.toolbarIcon)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if isSelected(source) {
                            Text(localized("使用中"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(DSColor.accent)
                                .clipShape(Capsule())
                        }
                    }

                    Text(source.urlTemplate)
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.textSecondary.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    selectSource(source)
                } label: {
                    Label(localized("設為使用"), systemImage: "checkmark.circle")
                }

                Button {
                    testPlayback(source)
                } label: {
                    Label(localized("測試播放"), systemImage: "play.circle")
                }

                Button {
                    copySourceJSON(source)
                } label: {
                    Label(localized("複製 JSON"), systemImage: "doc.on.doc")
                }

                Divider()

                Button(role: .destructive) {
                    deleteSource(source)
                } label: {
                    Label(localized("刪除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(90))
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 14)
    }

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 64))
                .foregroundColor(Color.secondary.opacity(0.35))
            Text(localized("尚無語音源"))
                .font(.title2.weight(.semibold))
            Text(localized("點擊右上角 ↓ 匯入 Legado 語音源 JSON"))
                .font(.subheadline)
                .foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showSourceFileImporter = true
            } label: {
                Label(localized("匯入語音源 JSON"), systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(DSColor.accent)
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding()
    }

    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            Text(localized("已載入") + " \(gs.importedTTSSources.count) " + localized("個語音源"))
                .font(.system(size: 13))
                .foregroundColor(DSColor.textSecondary)
                .lineLimit(1)

            Spacer()

            Button(role: .destructive) {
                clearSources()
            } label: {
                Text(localized("清除已匯入語音源"))
                    .font(.system(size: 13))
                    .foregroundColor(gs.importedTTSSources.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(gs.importedTTSSources.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    private var networkImportSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network").foregroundColor(DSColor.accent)
                    Text(localized("輸入語音源 JSON 的網路地址，支援直接返回 JSON 的 URL。"))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                TextField(localized("語音源 JSON URL"), text: $sourceListURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal)

                if isImportingSources {
                    ProgressView()
                        .padding(.top, 24)
                }

                Spacer()
            }
            .navigationTitle(localized("網路導入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) {
                        showNetworkImport = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("匯入")) {
                        Task { await importTTSSources() }
                    }
                    .font(.body.weight(.semibold))
                    .disabled(sourceListURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingSources)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func toastBanner(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(DSColor.accent)
            .clipShape(Capsule())
            .shadow(radius: 6)
            .padding(.top, 12)
    }

    private func dismissSettings() {
        presentationMode.wrappedValue.dismiss()
    }

    private func isSelected(_ source: ImportedTTSSource) -> Bool {
        gs.httpTtsUrlTemplate == source.urlTemplate
    }

    private func selectSource(_ source: ImportedTTSSource) {
        gs.httpTtsUrlTemplate = source.urlTemplate
        gs.httpTtsHeaders = source.headers
    }

    private func testPlayback(_ source: ImportedTTSSource) {
        selectSource(source)
        switch testCoordinator.playbackState {
        case .playing:
            testCoordinator.stop(reason: "restart source test playback")
        case .paused:
            testCoordinator.stop(reason: "restart source test playback")
        case .stopped:
            break
        }
        testCoordinator.speak(text: "這是一段測試文字，用於確認 HTTP TTS 引擎設定是否正確。", title: "測試")
    }

    private func copySourceJSON(_ source: ImportedTTSSource) {
        if let data = try? JSONEncoder().encode(source),
           let string = String(data: data, encoding: .utf8) {
            UIPasteboard.general.string = string
            withAnimation { sourceImportMessage = localized("已複製語音源 JSON") }
        }
    }

    private func deleteSource(_ source: ImportedTTSSource) {
        gs.importedTTSSources.removeAll { $0.id == source.id }
        if isSelected(source) {
            gs.httpTtsUrlTemplate = ""
            gs.httpTtsHeaders = [:]
            testCoordinator.stop(reason: "deleted selected source")
        }
    }

    private func clearSources() {
        gs.importedTTSSources = []
        gs.httpTtsUrlTemplate = ""
        gs.httpTtsHeaders = [:]
        testCoordinator.stop(reason: "cleared sources")
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
