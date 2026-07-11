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
    @State private var loginSource: ImportedTTSSource?
    @State private var loginFieldValues: [String: String] = [:]
    @State private var showLoginSuccess: Bool = false

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
                    sourceList

                    Divider()

                    bottomToolbar
                }
            }
            .navigationTitle(localized("語音朗讀設定"))
            .toolbarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜索語音源")
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismissSettings() } label: {
                        Image(systemName: "xmark")
                    }
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
                        Image(systemName: "plus")
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
            .sheet(item: $loginSource) { source in
                TTSSourceLoginView(source: source) {
                    loginSource = nil
                }
            }
            .onDisappear {
                testCoordinator.stop()
            }
    }

    // MARK: - Private

    // MARK: - Source list

    private var sourceList: some View {
        List {
            systemVoiceSourceRow
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.visible)

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
                    .font(DSFont.fixed(size: 20))
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
                                .font(DSFont.fixed(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(DSColor.accent)
                                .clipShape(Capsule())
                        }
                    }

                    Text(source.urlTemplate)
                        .font(DSFont.fixed(size: 11))
                        .foregroundColor(DSColor.textSecondary.opacity(0.6))
                        .lineLimit(1)

                    if source.loginUi != nil {
                        Text(localized("需設定帳號"))
                            .font(DSFont.fixed(size: 10))
                            .foregroundColor(DSColor.accent)
                            .lineLimit(1)
                    }
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

                if source.loginUi != nil {
                    Button {
                        openLoginForm(source)
                    } label: {
                        Label(localized("帳號設定"), systemImage: "person.fill")
                    }
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
                    .font(DSFont.fixed(size: 18))
                    .foregroundColor(
                        selectedSourceIds == filteredSourceIds && !filteredSources.isEmpty
                            ? DSColor.accent : Color(UIColor.systemGray3)
                    )
                    Text(localized("全選") + "(\(selectedSourceIds.count)/\(gs.importedTTSSources.count))")
                        .font(DSFont.fixed(size: 13))
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
                    .font(DSFont.fixed(size: 13))
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
                    .font(DSFont.fixed(size: 13))
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
                        .font(DSFont.caption)
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
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNetworkImport = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await importTTSSources() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(sourceListURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingSources)
                }
            }
        }
    }

    private func toastBanner(_ text: String) -> some View {
        Text(text)
            .font(DSFont.subheadline.weight(.medium))
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

    private func selectSystemVoice() {
        gs.ttsUseSystemVoice = true
        gs.httpTtsUrlTemplate = ""
        gs.httpTtsHeaders = [:]
    }

    private var isSystemVoiceSelected: Bool {
        gs.httpTtsUrlTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var systemVoiceSourceRow: some View {
        HStack(spacing: 0) {
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
                                .font(DSFont.fixed(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(DSColor.accent)
                                .clipShape(Capsule())
                        }
                    }

                    Text(localized("免網路，使用裝置內建語音朗讀"))
                        .font(DSFont.fixed(size: 11))
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
                    .font(DSFont.fixed(size: 22))
                    .foregroundColor(DSColor.accent)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 14)
        .padding(.leading, 16)
        .contentShape(Rectangle())
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
        LoginManager.shared.clearLogin(sourceUrl: source.id)
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
        for id in selected {
            LoginManager.shared.clearLogin(sourceUrl: id)
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
        for source in gs.importedTTSSources {
            LoginManager.shared.clearLogin(sourceUrl: source.id)
        }
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

    private func openLoginForm(_ source: ImportedTTSSource) {
        loginFieldValues = LoginManager.shared.getLoginInfo(sourceUrl: source.id) ?? [:]
        loginSource = source
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

// MARK: - TTS Source Login View

struct TTSSourceLoginView: View {
    let source: ImportedTTSSource
    let onDismiss: () -> Void

    @State private var fieldValues: [String: String] = [:]
    @State private var saved = false

    private let fields: [LoginField]

    init(source: ImportedTTSSource, onDismiss: @escaping () -> Void) {
        self.source = source
        self.onDismiss = onDismiss
        let loginInfo = LoginManager.shared.getLoginInfo(sourceUrl: source.id) ?? [:]
        _fieldValues = State(initialValue: loginInfo)
        if let ui = source.loginUi {
            fields = LoginManager.shared.parseLoginUi(ui)
        } else {
            fields = []
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if fields.isEmpty {
                    Text(localized("無可設定的欄位"))
                        .foregroundColor(.secondary)
                }
                ForEach(fields) { field in
                    fieldView(field)
                }
            }
            .navigationTitle(source.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(localized("取消")) { onDismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localized("儲存")) { saveLoginInfo() }
                        .disabled(saved)
                }
            }
            .overlay(alignment: .top) {
                if saved {
                    Text(localized("已儲存"))
                        .font(DSFont.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(DSColor.accent)
                        .clipShape(Capsule())
                        .shadow(radius: 6)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                onDismiss()
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: LoginField) -> some View {
        let value = Binding<String>(
            get: { fieldValues[field.name] ?? field.defaultValue ?? "" },
            set: { fieldValues[field.name] = $0 }
        )
        switch field.type {
        case .text:
            LabeledContent(field.name) {
                TextField(field.options.first ?? "", text: value)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
        case .password:
            LabeledContent(field.name) {
                SecureField(field.options.first ?? "", text: value)
                    .multilineTextAlignment(.trailing)
            }
        case .select:
            Picker(field.name, selection: value) {
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        case .button:
            Section {
                Button(field.name) {
                    handleButtonAction(field)
                }
            }
        }
    }

    private func saveLoginInfo() {
        LoginManager.shared.storeLoginInfo(sourceUrl: source.id, info: fieldValues)
        withAnimation { saved = true }
    }

    private func handleButtonAction(_ field: LoginField) {
        guard let action = field.action else { return }
        LoginManager.shared.storeLoginInfo(sourceUrl: source.id, info: fieldValues)
        // Execute button action JS if it starts with @js:
        if action.hasPrefix("@js:") || action.hasPrefix("<js>") {
            let jsCode = action.hasPrefix("@js:")
                ? String(action.dropFirst(4))
                : String(action.dropFirst(4).dropLast(5))
            let engine = JSCoreEngine()
            engine.sourceBridge.getLoginInfoMapHandler = {
                LoginManager.shared.getLoginInfo(sourceUrl: source.id) ?? [:]
            }
            engine.sourceBridge.putLoginInfoHandler = { info in
                if let d = info.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                    LoginManager.shared.storeLoginInfo(sourceUrl: source.id, info: dict)
                    fieldValues = dict
                }
            }
            _ = engine.evaluate(jsCode, result: nil, bindings: [
                "baseUrl": source.urlTemplate
            ])
        }
    }
}

extension LoginField: Identifiable {
    var id: String { name }
}

#Preview {
    TTSSettingsView()
}
