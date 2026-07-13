import SwiftUI
import UIKit

// MARK: - Edit Source Sheet

/// Edits an existing RSS source: name, feed URL, and folder.
/// Changing the URL re-validates by fetching, then refreshes the cached articles.
/// If the new URL can't be reached the user is asked whether to keep it anyway
/// (the original address is preserved on cancel).
struct EditRSSSourceSheet: View {
    private static let rootFolderID = "__rss_root_folder__"

    let source: RSSSource
    @ObservedObject var store: RSSStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var url: String
    @State private var selectedFolderID: String
    @State private var isSaving = false
    @State private var showUnreachableConfirm = false
    @State private var errorMessage: String?

    init(source: RSSSource, store: RSSStore) {
        self.source = source
        self.store = store
        _name = State(initialValue: source.name)
        _url = State(initialValue: source.url)
        let folderID = store.orderedFolders().first { $0.name == source.sourceGroup }?.id
        _selectedFolderID = State(initialValue: folderID ?? Self.rootFolderID)
    }

    private var folders: [RSSFolder] { store.orderedFolders() }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedURL.isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(localized("來源名稱"))) {
                    TextField(localized("來源名稱"), text: $name)
                }

                Section(header: Text(localized("RSS 網址"))) {
                    TextField("https://", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: url) { _, _ in errorMessage = nil }
                }

                Section(header: Text(localized("資料夾"))) {
                    Picker(localized("資料夾"), selection: $selectedFolderID) {
                        Text(localized("無資料夾")).tag(Self.rootFolderID)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(localized("編輯訂閱"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(!canSave)
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView(localized("正在驗證網址…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(localized("無法解析此網址"), isPresented: $showUnreachableConfirm) {
                Button(localized("仍要儲存"), role: .destructive) {
                    commit()
                    dismiss()
                }
                Button(localized("取消"), role: .cancel) {}
            } message: {
                Text(localized("此 RSS 網址無法取得內容，是否仍要儲存？"))
            }
        }
    }

    @MainActor
    private func save() async {
        guard !trimmedURL.isEmpty else { return }

        guard let parsed = URL(string: trimmedURL),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            errorMessage = localized("RSS URL 無效")
            return
        }
        errorMessage = nil

        // Name / folder-only edits don't need a network round-trip.
        guard trimmedURL != source.url else {
            commit()
            dismiss()
            return
        }

        isSaving = true
        defer { isSaving = false }

        var probe = updatedSource()
        probe.faviconURL = nil
        probe.homepageURL = nil

        let fetcher = RSSFetcher()
        await fetcher.fetchItems(from: probe, metadata: nil)

        guard fetcher.error == nil else {
            showUnreachableConfirm = true
            return
        }

        store.clearFeedMetadata(for: source.id)
        commit()
        store.applyResolvedFeedURL(fetcher.resolvedFeedURL, homepageURL: fetcher.resolvedHomepageURL, to: source.id)
        if let response = fetcher.response {
            store.applyFeedResponse(response, for: source.id)
        } else {
            store.mergeFetchedItems(fetcher.items, for: source.id)
        }
        dismiss()
    }

    /// Builds the edited source, recomputing sort order when it moves to a new folder.
    private func updatedSource() -> RSSSource {
        var updated = source
        updated.name = trimmedName.isEmpty ? source.name : trimmedName
        updated.url = trimmedURL

        let folder = folders.first { $0.id == selectedFolderID }
        let newGroup = folder?.name
        if newGroup != source.sourceGroup {
            updated.sourceGroup = newGroup
            updated.sortOrder = store.nextSourceSortOrder(in: folder)
        }
        return updated
    }

    private func commit() {
        var updated = updatedSource()
        if trimmedURL != source.url {
            // The favicon/home page belonged to the old feed — let them re-resolve.
            updated.faviconURL = nil
            updated.homepageURL = nil
        }
        store.updateSource(updated)
    }
}

// MARK: - Organize Sheet (reorder)

/// Drag-to-reorder for RSS folders and sources, plus tap-to-edit each source.
/// Uses a native `List` with `EditButton` + `.onMove`.
struct RSSOrganizeSheet: View {
    @ObservedObject var store: RSSStore
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive

    @State private var sourceToEdit: RSSSource?

    var body: some View {
        NavigationStack {
            List {
                let folders = store.orderedFolders()

                if folders.count > 1 {
                    Section(header: Text(localized("資料夾"))) {
                        ForEach(folders) { folder in
                            Label(folder.name, systemImage: "folder")
                                .foregroundStyle(.primary)
                        }
                        .onMove { offsets, destination in
                            store.moveFolders(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                }

                ForEach(folders) { folder in
                    let folderSources = store.sources(in: folder)
                    if !folderSources.isEmpty {
                        Section(header: Text(folder.name)) {
                            ForEach(folderSources) { source in
                                sourceRow(source)
                            }
                            .onMove { offsets, destination in
                                store.moveSources(inFolderNamed: folder.name, fromOffsets: offsets, toOffset: destination)
                            }
                        }
                    }
                }

                let rootSources = store.rootSources()
                if !rootSources.isEmpty {
                    Section(header: Text(folders.isEmpty ? "" : localized("未分類"))) {
                        ForEach(rootSources) { source in
                            sourceRow(source)
                        }
                        .onMove { offsets, destination in
                            store.moveSources(inFolderNamed: nil, fromOffsets: offsets, toOffset: destination)
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(localized("整理訂閱"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .rss)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation {
                            editMode = (editMode == .active) ? .inactive : .active
                        }
                    } label: {
                        Image(systemName: editMode == .active ? "xmark" : "checklist")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .sheet(item: $sourceToEdit) { source in
                EditRSSSourceSheet(source: source, store: store)
            }
        }
    }

    private func sourceRow(_ source: RSSSource) -> some View {
        Button {
            sourceToEdit = source
        } label: {
            HStack(spacing: 12) {
                RSSFaviconView(source: source, size: 24)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(DSFont.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(source.url)
                        .font(DSFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
    }
}

#Preview("Edit Source") {
    EditRSSSourceSheet(
        source: RSSSource(name: "Example Feed", url: "https://example.com/feed.xml"),
        store: RSSStore.shared
    )
}

#Preview("Organize") {
    RSSOrganizeSheet(store: RSSStore.shared)
}
