import SwiftUI
import UniformTypeIdentifiers

// MARK: - Book Source List (Legado Style)

struct BookSourceListView: View {
    @ObservedObject private var store = BookSourceStore.shared
    @ObservedObject private var gs = GlobalSettings.shared
    @State private var showAdd = false
    @State private var editingSource: BookSource? = nil
    @State private var showImport = false
    @State private var showImportFile = false
    @State private var importJSON = ""
    @State private var importError: String? = nil
    @State private var importSuccess: String? = nil
    @State private var showNetworkImport = false
    @State private var importURLString = ""
    @State private var networkImportLoading = false
    @State private var loginSource: BookSource? = nil
    @Environment(\.presentationMode) var dismiss

    @State private var selectedIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var showDeleteConfirm = false
    @State private var showMoreMenu = false

    private var filteredSources: [BookSource] {
        if searchText.isEmpty { return store.sources }
        let q = searchText.lowercased()
        return store.sources.filter {
            $0.bookSourceName.lowercased().contains(q) || $0.bookSourceUrl.lowercased().contains(q)
                || $0.bookSourceGroup.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableWideWidth) {
                VStack(spacing: 0) {
                    if store.sources.isEmpty {
                        emptyView
                    } else {
                        sourceList
                    }

                    Divider()

                    bottomToolbar
                }
            }
            .navigationTitle(localized("書源管理"))
            .toolbarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: localized("搜索書源")
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("關閉")) { dismiss.wrappedValue.dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showImport = true
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
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    Menu {
                        Button {
                            enableAll()
                        } label: {
                            Label(localized("全部啟用"), systemImage: "checkmark.circle")
                        }
                        Button {
                            disableAll()
                        } label: {
                            Label(localized("全部停用"), systemImage: "xmark.circle")
                        }
                        Divider()
                        Button {
                            exportSelected()
                        } label: {
                            Label(localized("匯出選中"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(selectedIds.isEmpty)
                        Button {
                            exportAll()
                        } label: {
                            Label(localized("匯出全部"), systemImage: "square.and.arrow.up.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                    BookSourceEditView(source: BookSource()) { src in
                        store.add(src)
                    }
                }
            }
            .sheet(item: $editingSource) { src in
                AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                    BookSourceEditView(source: src) { updated in
                        store.update(updated)
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    importSheet
                }
            }
            .sheet(isPresented: $showNetworkImport) {
                AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                    networkImportSheet
                }
            }
            .sheet(item: $loginSource) { src in
                if src.loginUi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    BookSourceLoginWebView(source: src) {
                        loginSource = nil
                    }
                } else {
                    BookSourceFormLoginView(source: src) {
                        loginSource = nil
                    }
                }
            }
            .alert(localized("確認刪除"), isPresented: $showDeleteConfirm) {
                Button(localized("取消"), role: .cancel) {}
                Button(localized("刪除"), role: .destructive) {
                    deleteSelected()
                }
            } message: {
                Text(localized("確定要刪除選中的") + " \(selectedIds.count) " + localized("個書源嗎？"))
            }
            .overlay(alignment: .top) {
                if let msg = importSuccess {
                    toastBanner(msg, color: .green)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation { importSuccess = nil }
                            }
                        }
                }
                if let err = importError {
                    toastBanner(err, color: .red)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation { importError = nil }
                            }
                        }
                }
            }
            .onChange(of: store.sources.map(\.id)) { _, sourceIds in
                selectedIds.formIntersection(Set(sourceIds))
            }
        }
    }

    // MARK: - Source List
    private var sourceList: some View {
        List {
            ForEach(filteredSources) { source in
                sourceRow(source: source)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func sourceRow(source: BookSource) -> some View {
        HStack(spacing: 0) {
            Button {
                toggleSelection(source.id)
            } label: {
                Image(
                    systemName: selectedIds.contains(source.id) ? "checkmark.square.fill" : "square"
                )
                .font(.system(size: 20))
                .foregroundColor(
                    selectedIds.contains(source.id) ? DSColor.accent : Color(UIColor.systemGray3))
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName.isEmpty ? localized("未命名書源") : source.bookSourceName)
                        .font(DSFont.toolbarIcon)
                        .foregroundColor(source.enabled ? .primary : .secondary)
                        .lineLimit(1)

                    if !source.bookSourceGroup.isEmpty {
                        Text("(\(source.bookSourceGroup))")
                            .font(.system(size: 13))
                            .foregroundColor(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                if !source.bookSourceUrl.isEmpty {
                    Text(source.bookSourceUrl)
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.textSecondary.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                "",
                isOn: Binding(
                    get: { source.enabled },
                    set: { _ in store.toggle(id: source.id) }
                )
            )
            .labelsHidden()
            .scaleEffect(0.85)
            .padding(.trailing, 4)

            Button {
                editingSource = source
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            Menu {
                Button {
                    editingSource = source
                } label: {
                    Label(localized("編輯"), systemImage: "pencil")
                }
                Button {
                    if let data = try? JSONEncoder().encode(source),
                        let str = String(data: data, encoding: .utf8)
                    {
                        UIPasteboard.general.string = str
                        withAnimation { importSuccess = localized("已複製書源 JSON") }
                    }
                } label: {
                    Label(localized("複製 JSON"), systemImage: "doc.on.doc")
                }
                Button {
                    store.toggle(id: source.id)
                } label: {
                    Label(
                        localized(source.enabled ? "停用" : "啟用"),
                        systemImage: source.enabled ? "xmark.circle" : "checkmark.circle")
                }
                if !source.loginUrl.isEmpty {
                    Button {
                        loginSource = source
                    } label: {
                        Label(localized("Cookie 驗證登入"), systemImage: "key.fill")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    selectedIds.remove(source.id)
                    store.delete(id: source.id)
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
        .opacity(source.enabled ? 1 : 0.6)
    }

    // MARK: - Bottom Toolbar
    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            Button {
                toggleSelectAll()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: selectedIds.count == filteredSources.count
                            && !filteredSources.isEmpty
                            ? "checkmark.square.fill" : "square"
                    )
                    .font(.system(size: 18))
                    .foregroundColor(
                        selectedIds.count == filteredSources.count && !filteredSources.isEmpty
                            ? DSColor.accent : Color(UIColor.systemGray3))
                    Text(localized("全選") + "(\(selectedIds.count)/\(store.sources.count))")
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

            Spacer().frame(width: 10)

            Button {
                if !selectedIds.isEmpty {
                    showDeleteConfirm = true
                }
            } label: {
                Text(localized("刪除"))
                    .font(.system(size: 13))
                    .foregroundColor(selectedIds.isEmpty ? .secondary : .red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty)

            Spacer().frame(width: 10)

            Menu {
                Button {
                    enableSelected()
                } label: {
                    Label(localized("啟用選中"), systemImage: "checkmark.circle")
                }
                .disabled(selectedIds.isEmpty)
                Button {
                    disableSelected()
                } label: {
                    Label(localized("停用選中"), systemImage: "xmark.circle")
                }
                .disabled(selectedIds.isEmpty)
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

    // MARK: - Batch Operations

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func toggleSelectAll() {
        let allIds = Set(filteredSources.map { $0.id })
        if selectedIds == allIds {
            selectedIds.removeAll()
        } else {
            selectedIds = allIds
        }
    }

    private func invertSelection() {
        let allIds = Set(filteredSources.map { $0.id })
        selectedIds = allIds.subtracting(selectedIds)
    }

    private func deleteSelected() {
        let idsToDelete = selectedIds
        selectedIds.removeAll()
        store.delete(ids: idsToDelete)
    }

    private func enableSelected() {
        for id in selectedIds {
            if let idx = store.sources.firstIndex(where: { $0.id == id }),
                !store.sources[idx].enabled
            {
                store.toggle(id: id)
            }
        }
    }

    private func disableSelected() {
        for id in selectedIds {
            if let idx = store.sources.firstIndex(where: { $0.id == id }),
                store.sources[idx].enabled
            {
                store.toggle(id: id)
            }
        }
    }

    private func enableAll() {
        for source in store.sources where !source.enabled {
            store.toggle(id: source.id)
        }
    }

    private func disableAll() {
        for source in store.sources where source.enabled {
            store.toggle(id: source.id)
        }
    }

    private func exportSelected() {
        let json = store.exportToJSON(ids: Array(selectedIds))
        UIPasteboard.general.string = json
        withAnimation { importSuccess = localized("已複製") + " \(selectedIds.count) " + localized("個書源到剪貼簿") }
    }

    private func exportAll() {
        let json = store.exportToJSON()
        UIPasteboard.general.string = json
        withAnimation { importSuccess = localized("已複製全部") + " \(store.sources.count) " + localized("個書源到剪貼簿") }
    }

    // MARK: - Empty State
    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.circle")
                .font(.system(size: 64))
                .foregroundColor(Color.secondary.opacity(0.35))
            Text(localized("尚無書源"))
                .font(.title2.weight(.semibold))
            Text(localized("點擊右上角 + 手動新增\n或 ↓ 貼上 Legado 書源 JSON 匯入"))
                .font(.subheadline).foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showImport = true
            } label: {
                Label(localized("匯入書源 JSON"), systemImage: "square.and.arrow.down")
                    .font(.headline).foregroundColor(.white)
                    .padding(.horizontal, 28).padding(.vertical, 13)
                    .background(DSColor.accent).clipShape(Capsule())
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Import Sheet
    private var importSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundColor(DSColor.accent)
                    Text(localized("貼上 Legado 格式的書源 JSON（支援單個 {} 或陣列 []），或選取 .json 文件。"))
                        .font(.caption).foregroundColor(DSColor.textSecondary)
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                TextEditor(text: $importJSON)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .frame(maxHeight: 280)

                Button {
                    showImportFile = true
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
            .navigationTitle(localized("匯入書源"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) {
                        showImport = false
                        importJSON = ""
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("匯入")) {
                        doImport(importJSON)
                    }
                    .font(.body.weight(.semibold))
                    .disabled(importJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .fileImporter(
            isPresented: $showImportFile,
            allowedContentTypes: [UTType.json, UTType.plainText,
                                  UTType(filenameExtension: "yds") ?? .data,
                                  UTType(filenameExtension: "xbs") ?? .data,
                                  UTType(filenameExtension: "mrs") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    doImportData(data, ext: url.pathExtension)
                } else {
                    importError = localized("無法讀取文件")
                }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
    }

    private func doImportData(_ data: Data, ext: String) {
        do {
            let count = try store.importFromData(data, fileExtension: ext)
            withAnimation {
                importSuccess = localized("成功匯入") + " \(count) " + localized("個書源")
                importJSON = ""
                showImport = false
            }
        } catch {
            withAnimation { importError = error.localizedDescription }
        }
    }

    private func doImport(_ json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let count = try store.importFromJSON(trimmed)
            withAnimation {
                importSuccess = localized("成功匯入") + " \(count) " + localized("個書源")
                importJSON = ""
                showImport = false
            }
        } catch {
            withAnimation { importError = error.localizedDescription }
        }
    }

    // MARK: - Network Import Sheet

    private var networkImportSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network").foregroundColor(DSColor.accent)
                    Text(localized("輸入書源 JSON 的網路地址，支援直接返回 JSON 的 URL。"))
                        .font(.caption).foregroundColor(DSColor.textSecondary)
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding()

                TextField("https://example.com/booksource.json", text: $importURLString)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal)

                if networkImportLoading {
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
                        importURLString = ""
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("匯入")) {
                        doNetworkImport()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(
                        importURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || networkImportLoading)
                }
            }
        }
    }

    private func doNetworkImport() {
        let urlString = importURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            withAnimation { importError = localized("無效的 URL") }
            return
        }
        networkImportLoading = true
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                networkImportLoading = false
                if let err = error {
                    withAnimation { importError = err.localizedDescription }
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) else {
                    withAnimation { importError = localized("無法解析伺服器回應") }
                    return
                }
                showNetworkImport = false
                importURLString = ""
                doImport(text)
            }
        }.resume()
    }

    // MARK: - Utilities
    @ViewBuilder
    private func toastBanner(_ msg: String, color: Color) -> some View {
        Text(msg)
            .font(.caption).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(color.opacity(0.9)).clipShape(Capsule())
            .padding(.top, 8)
    }
}
