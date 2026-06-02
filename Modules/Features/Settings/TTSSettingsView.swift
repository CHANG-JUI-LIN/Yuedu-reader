import AVFoundation
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
    @State private var selectedSourceIds: Set<String> = []

    private var filteredSources: [ImportedTTSSource] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return gs.importedTTSSources }
        return gs.importedTTSSources.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.urlTemplate.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredSourceIds: Set<String> {
        Set(filteredSources.map(\.id))
    }

    var body: some View {
        NavigationStack {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableWideWidth) {
                VStack(spacing: 0) {
                    searchBar

                    Divider()

                    systemVoiceSection

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
            .toolbarTitleDisplayMode(.inlineLarge)
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
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
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

    // MARK: - System (offline) voice

    private var systemVoiceSection: some View {
        VStack(spacing: 0) {
            systemVoiceRow
            if isSystemVoiceSelected {
                systemVoicePickerRow
            }
        }
    }

    private var systemVoiceRow: some View {
        HStack(spacing: 0) {
            Image(systemName: isSystemVoiceSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 20))
                .foregroundColor(isSystemVoiceSelected ? DSColor.accent : Color(UIColor.systemGray3))
                .padding(.leading, 16)
                .padding(.trailing, 12)

            Button {
                selectSystemVoice()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(localized("系統離線語音"))
                            .font(DSFont.toolbarIcon)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if isSystemVoiceSelected {
                            Text(localized("使用中"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(DSColor.accent)
                                .clipShape(Capsule())
                        }
                    }

                    Text(localized("免網路，使用裝置內建語音朗讀"))
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.textSecondary.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                testSystemPlayback()
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 22))
                    .foregroundColor(DSColor.accent)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var systemVoicePickerRow: some View {
        HStack {
            Text(localized("語音"))
                .font(.system(size: 13))
                .foregroundColor(DSColor.textSecondary)

            Spacer()

            Menu {
                Button {
                    gs.ttsSystemVoiceIdentifier = ""
                } label: {
                    voiceMenuLabel(localized("自動"), selected: gs.ttsSystemVoiceIdentifier.isEmpty)
                }
                ForEach(availableSystemVoices, id: \.identifier) { voice in
                    Button {
                        gs.ttsSystemVoiceIdentifier = voice.identifier
                    } label: {
                        voiceMenuLabel(voiceLabel(voice), selected: gs.ttsSystemVoiceIdentifier == voice.identifier)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedSystemVoiceName)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var availableSystemVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let lang = voice.language.lowercased()
                return lang.hasPrefix("zh") || lang.hasPrefix("en")
            }
            .sorted { lhs, rhs in
                lhs.language == rhs.language
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhs.language < rhs.language
            }
    }

    private var selectedSystemVoiceName: String {
        guard !gs.ttsSystemVoiceIdentifier.isEmpty,
              let voice = AVSpeechSynthesisVoice(identifier: gs.ttsSystemVoiceIdentifier) else {
            return localized("自動")
        }
        return voice.name
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        "\(voice.name) (\(voice.language))"
    }

    @ViewBuilder
    private func voiceMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
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
                toggleSelection(source.id)
            } label: {
                Image(systemName: selectedSourceIds.contains(source.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(
                        selectedSourceIds.contains(source.id) ? DSColor.accent : Color(UIColor.systemGray3)
                    )
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
        HStack(spacing: 0) {
            Button {
                toggleSelectAll()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: selectedSourceIds == filteredSourceIds && !filteredSources.isEmpty
                            ? "checkmark.square.fill" : "square"
                    )
                    .font(.system(size: 18))
                    .foregroundColor(
                        selectedSourceIds == filteredSourceIds && !filteredSources.isEmpty
                            ? DSColor.accent : Color(UIColor.systemGray3)
                    )
                    Text(localized("全選") + "(\(selectedSourceIds.count)/\(gs.importedTTSSources.count))")
                        .font(.system(size: 13))
                        .foregroundColor(DSColor.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)

            Spacer()

            Button {
                invertSelection()
            } label: {
                Text(localized("反選"))
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(filteredSources.isEmpty)

            Spacer().frame(width: 10)

            Button(role: .destructive) {
                deleteSelectedSources()
            } label: {
                Text(localized("刪除"))
                    .font(.system(size: 13))
                    .foregroundColor(selectedSourceIds.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(selectedSourceIds.isEmpty)

            Spacer().frame(width: 10)

            Menu {
                Button(role: .destructive) {
                    clearSources()
                } label: {
                    Label(localized("清除已匯入語音源"), systemImage: "trash")
                }
                .disabled(gs.importedTTSSources.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(90))
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    private var networkImportSheet: some View {
        NavigationStack {
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
            .toolbarTitleDisplayMode(.inlineLarge)
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
        !gs.ttsUseSystemVoice && gs.httpTtsUrlTemplate == source.urlTemplate
    }

    private func selectSource(_ source: ImportedTTSSource) {
        gs.ttsUseSystemVoice = false
        gs.httpTtsUrlTemplate = source.urlTemplate
        gs.httpTtsHeaders = source.headers
    }

    private var isSystemVoiceSelected: Bool {
        gs.ttsUseSystemVoice
    }

    private func selectSystemVoice() {
        gs.ttsUseSystemVoice = true
    }

    private func testSystemPlayback() {
        selectSystemVoice()
        testCoordinator.stop(reason: "restart system voice test")
        testCoordinator.speak(text: "這是一段測試文字，用於確認系統離線語音是否正常。", title: "測試")
    }

    private func toggleSelection(_ id: String) {
        if selectedSourceIds.contains(id) {
            selectedSourceIds.remove(id)
        } else {
            selectedSourceIds.insert(id)
        }
    }

    private func toggleSelectAll() {
        let allIds = filteredSourceIds
        if selectedSourceIds == allIds {
            selectedSourceIds.removeAll()
        } else {
            selectedSourceIds = allIds
        }
    }

    private func invertSelection() {
        selectedSourceIds = filteredSourceIds.subtracting(selectedSourceIds)
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
        selectedSourceIds.remove(source.id)
        if isSelected(source) {
            gs.httpTtsUrlTemplate = ""
            gs.httpTtsHeaders = [:]
            testCoordinator.stop(reason: "deleted selected source")
        }
    }

    private func deleteSelectedSources() {
        let selected = selectedSourceIds
        guard !selected.isEmpty else { return }
        let deletingActiveSource = gs.importedTTSSources.contains {
            selected.contains($0.id) && isSelected($0)
        }
        gs.importedTTSSources.removeAll { selected.contains($0.id) }
        selectedSourceIds.removeAll()
        if deletingActiveSource {
            gs.httpTtsUrlTemplate = ""
            gs.httpTtsHeaders = [:]
            testCoordinator.stop(reason: "deleted selected sources")
        }
    }

    private func clearSources() {
        gs.importedTTSSources = []
        selectedSourceIds.removeAll()
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
            sourceListURL = ""
            showNetworkImport = false
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

#Preview {
    TTSSettingsView()
}
