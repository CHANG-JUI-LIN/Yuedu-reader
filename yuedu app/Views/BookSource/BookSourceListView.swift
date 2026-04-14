import SwiftUI
import UniformTypeIdentifiers

// MARK: - 書源列表主頁（Legado 風格）

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
    @Environment(\.presentationMode) var dismiss

    // 批量操作
    @State private var selectedIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var showDeleteConfirm = false
    @State private var showMoreMenu = false

    // 過濾後的書源列表
    private var filteredSources: [BookSource] {
        if searchText.isEmpty { return store.sources }
        let q = searchText.lowercased()
        return store.sources.filter {
            $0.bookSourceName.lowercased().contains(q) || $0.bookSourceUrl.lowercased().contains(q)
                || $0.bookSourceGroup.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationView {
            AdaptiveSheetContainer(maxWidth: 980) {
                VStack(spacing: 0) {
                    // 搜索欄
                    searchBar

                    Divider()

                    // 列表
                    if store.sources.isEmpty {
                        emptyView
                    } else {
                        sourceList
                    }

                    Divider()

                    // 底部工具欄
                    bottomToolbar
                }
            }
            .navigationTitle(gs.t("書源管理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("關閉")) { dismiss.wrappedValue.dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    // 更多選項
                    Menu {
                        Button {
                            enableAll()
                        } label: {
                            Label(gs.t("全部啟用"), systemImage: "checkmark.circle")
                        }
                        Button {
                            disableAll()
                        } label: {
                            Label(gs.t("全部停用"), systemImage: "xmark.circle")
                        }
                        Divider()
                        Button {
                            exportSelected()
                        } label: {
                            Label(gs.t("匯出選中"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(selectedIds.isEmpty)
                        Button {
                            exportAll()
                        } label: {
                            Label(gs.t("匯出全部"), systemImage: "square.and.arrow.up.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AdaptiveSheetContainer(maxWidth: 900) {
                    BookSourceEditView(source: BookSource()) { src in
                        store.add(src)
                    }
                }
            }
            .sheet(item: $editingSource) { src in
                AdaptiveSheetContainer(maxWidth: 900) {
                    BookSourceEditView(source: src) { updated in
                        store.update(updated)
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                AdaptiveSheetContainer(maxWidth: 820) {
                    importSheet
                }
            }
            .alert(gs.t("確認刪除"), isPresented: $showDeleteConfirm) {
                Button(gs.t("取消"), role: .cancel) {}
                Button(gs.t("刪除"), role: .destructive) {
                    deleteSelected()
                }
            } message: {
                Text(gs.t("確定要刪除選中的") + " \(selectedIds.count) " + gs.t("個書源嗎？"))
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
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 搜索欄
    private var searchBar: some View {
        DSSearchBar(placeholder: gs.t("搜索書源"), text: $searchText)
    }

    // MARK: - 書源列表
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
            // ── 勾選框 ──
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

            // ── 書源名稱 ──
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName.isEmpty ? gs.t("未命名書源") : source.bookSourceName)
                        .font(DSFont.toolbarIcon)
                        .foregroundColor(source.enabled ? .primary : .secondary)
                        .lineLimit(1)

                    // 分組標籤
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

            // ── 啟用開關 ──
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

            // ── 編輯按鈕 ──
            Button {
                editingSource = source
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(DSFont.toolbarIcon)
                    .foregroundColor(DSColor.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            // ── 更多選單 ──
            Menu {
                Button {
                    editingSource = source
                } label: {
                    Label(gs.t("編輯"), systemImage: "pencil")
                }
                Button {
                    // 複製書源 JSON
                    if let data = try? JSONEncoder().encode(source),
                        let str = String(data: data, encoding: .utf8)
                    {
                        UIPasteboard.general.string = str
                        withAnimation { importSuccess = gs.t("已複製書源 JSON") }
                    }
                } label: {
                    Label(gs.t("複製 JSON"), systemImage: "doc.on.doc")
                }
                Button {
                    store.toggle(id: source.id)
                } label: {
                    Label(
                        gs.t(source.enabled ? "停用" : "啟用"),
                        systemImage: source.enabled ? "xmark.circle" : "checkmark.circle")
                }
                Divider()
                Button(role: .destructive) {
                    store.delete(id: source.id)
                } label: {
                    Label(gs.t("刪除"), systemImage: "trash")
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

    // MARK: - 底部工具欄
    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // 全選
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
                    Text(gs.t("全選") + "(\(selectedIds.count)/\(store.sources.count))")
                        .font(.system(size: 13))
                        .foregroundColor(DSColor.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)

            Spacer()

            // 反選
            Button {
                invertSelection()
            } label: {
                Text(gs.t("反選"))
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color(UIColor.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer().frame(width: 10)

            // 刪除
            Button {
                if !selectedIds.isEmpty {
                    showDeleteConfirm = true
                }
            } label: {
                Text(gs.t("刪除"))
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

            // 批量操作選單
            Menu {
                Button {
                    enableSelected()
                } label: {
                    Label(gs.t("啟用選中"), systemImage: "checkmark.circle")
                }
                .disabled(selectedIds.isEmpty)
                Button {
                    disableSelected()
                } label: {
                    Label(gs.t("停用選中"), systemImage: "xmark.circle")
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

    // MARK: - 批量操作

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
        for id in selectedIds {
            store.delete(id: id)
        }
        selectedIds.removeAll()
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
        withAnimation { importSuccess = gs.t("已複製") + " \(selectedIds.count) " + gs.t("個書源到剪貼簿") }
    }

    private func exportAll() {
        let json = store.exportToJSON()
        UIPasteboard.general.string = json
        withAnimation { importSuccess = gs.t("已複製全部") + " \(store.sources.count) " + gs.t("個書源到剪貼簿") }
    }

    // MARK: - 空狀態
    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.circle")
                .font(.system(size: 64))
                .foregroundColor(Color.secondary.opacity(0.35))
            Text(gs.t("尚無書源"))
                .font(.title2.weight(.semibold))
            Text(gs.t("點擊右上角 + 手動新增\n或 ↓ 貼上 Legado 書源 JSON 匯入"))
                .font(.subheadline).foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showImport = true
            } label: {
                Label(gs.t("匯入書源 JSON"), systemImage: "square.and.arrow.down")
                    .font(.headline).foregroundColor(.white)
                    .padding(.horizontal, 28).padding(.vertical, 13)
                    .background(DSColor.accent).clipShape(Capsule())
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - 匯入 Sheet
    private var importSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundColor(DSColor.accent)
                    Text(gs.t("貼上 Legado 格式的書源 JSON（支援單個 {} 或陣列 []），或選取 .json 文件。"))
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
                    Label(gs.t("從文件選取 .json"), systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                Spacer()
            }
            .navigationTitle(gs.t("匯入書源"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("取消")) {
                        showImport = false
                        importJSON = ""
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(gs.t("匯入")) {
                        doImport(importJSON)
                    }
                    .font(.body.weight(.semibold))
                    .disabled(importJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .fileImporter(
            isPresented: $showImportFile,
            allowedContentTypes: [UTType.json, UTType.plainText]
        ) { result in
            switch result {
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    doImport(text)
                } else {
                    importError = gs.t("無法讀取文件")
                }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
    }

    private func doImport(_ json: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let count = try store.importFromJSON(trimmed)
            withAnimation {
                importSuccess = gs.t("成功匯入") + " \(count) " + gs.t("個書源")
                importJSON = ""
                showImport = false
            }
        } catch {
            withAnimation { importError = error.localizedDescription }
        }
    }

    // MARK: - 工具
    @ViewBuilder
    private func toastBanner(_ msg: String, color: Color) -> some View {
        Text(msg)
            .font(.caption).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(color.opacity(0.9)).clipShape(Capsule())
            .padding(.top, 8)
    }
}
