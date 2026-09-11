import SwiftUI
import UniformTypeIdentifiers

/// Uploads and folder changes are explicit operations scoped to the location the
/// user opened. A failed mutation never refreshes the catalog as if it succeeded.
struct RemoteLibraryManagementView: View {
    let connectionID: String
    let directoryURL: URL
    @Environment(\.appDependencies) private var dependencies
    @State private var capabilities: RemoteLibraryWriteCapabilities?
    @State private var loading = true
    @State private var importing = false
    @State private var folderName = ""
    @State private var task: Task<Void, Never>?
    @State private var isWorking = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Form {
            if loading {
                Section { ProgressView(localized("正在檢查書庫功能")) }.interfaceSectionSurface()
            }
            if let capabilities {
                if capabilities.canUpload {
                    Section {
                        Button { importing = true } label: {
                            Label(localized("上傳書籍到此書庫"), systemImage: "arrow.up.doc")
                        }
                        .disabled(isWorking)
                    } footer: {
                        Text(localized("選取的檔案會傳送到目前的遠端書庫；不會自動加入本機書架。"))
                            .dsSectionFooter()
                    }
                    .interfaceSectionSurface()
                }
                if capabilities.canCreateFolder {
                    Section {
                        TextField(localized("資料夾名稱"), text: $folderName)
                            .autocorrectionDisabled()
                        Button(localized("建立資料夾")) {
                            let name = folderName
                            perform {
                                _ = try await dependencies.remoteLibraryWriting.createFolder(name: name,
                                    connectionID: connectionID, directoryURL: directoryURL)
                                folderName = ""
                            }
                        }
                        .disabled(isWorking || folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .interfaceSectionSurface()
                }
                if let reason = capabilities.unsupportedReasonKey {
                    Section {
                        Label(localized(reason), systemImage: "info.circle")
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    .interfaceSectionSurface()
                }
            }
            if isWorking {
                Section {
                    ProgressView(localized("正在更新遠端書庫"))
                    Button(localized("取消"), role: .cancel) { task?.cancel() }
                }
                .interfaceSectionSurface()
            }
            if let message {
                Section {
                    Label(message, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(failed ? DSColor.destructive : DSColor.textSecondary)
                    if capabilities == nil {
                        Button(localized("重試")) { task = Task { await loadCapabilities() } }
                    }
                }
                .interfaceSectionSurface()
            }
        }
        .navigationTitle(localized("管理遠端書庫"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
        .task { await loadCapabilities() }
        .onDisappear { task?.cancel() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: ["epub", "pdf", "txt", "md", "markdown"].compactMap { UTType(filenameExtension: $0) },
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                perform {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    _ = try await dependencies.remoteLibraryWriting.upload(fileURL: url,
                        connectionID: connectionID, directoryURL: directoryURL)
                }
            case .failure(let error):
                message = error.localizedDescription; failed = true
            }
        }
    }

    private func loadCapabilities() async {
        loading = true
        defer { loading = false }
        do {
            capabilities = try await dependencies.remoteLibraryWriting.capabilities(
                connectionID: connectionID, directoryURL: directoryURL)
            message = nil
        } catch {
            guard !Task.isCancelled else { return }
            message = error.localizedDescription; failed = true
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true; message = nil
        task = Task { @MainActor in
            defer { isWorking = false }
            do {
                try await operation()
                message = localized("遠端書庫已更新")
                failed = false
                UIAccessibility.post(notification: .announcement, argument: message)
            } catch {
                message = Task.isCancelled ? localized("操作已取消，請重新整理書庫確認伺服器狀態") : error.localizedDescription
                failed = true
            }
        }
    }
}

struct RemoteLibraryBookEditor: View {
    let item: RemoteLibraryItem
    let capabilities: RemoteLibraryWriteCapabilities
    let onSaved: (RemoteLibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var store: BookStore
    @State private var title: String
    @State private var author: String
    @State private var filename: String
    @State private var working = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    init(item: RemoteLibraryItem, capabilities: RemoteLibraryWriteCapabilities,
         onSaved: @escaping (RemoteLibraryItem) -> Void) {
        self.item = item; self.capabilities = capabilities; self.onSaved = onSaved
        _title = State(initialValue: item.title)
        _author = State(initialValue: item.author ?? "")
        _filename = State(initialValue: item.formats.first?.url.lastPathComponent ?? "")
    }

    var body: some View {
        Form {
            Section {
                if capabilities.canEditMetadata {
                    TextField(localized("書名"), text: $title)
                    TextField(localized("作者"), text: $author)
                } else if capabilities.canMove {
                    TextField(localized("檔案名稱"), text: $filename).autocorrectionDisabled()
                }
            } footer: {
                Text(localized("儲存會修改遠端書庫，本機閱讀進度和書籤會保留。"))
                    .dsSectionFooter()
            }
            .disabled(working)
            .interfaceSectionSurface()
            if working {
                Section {
                    ProgressView(localized("正在更新遠端書庫"))
                    Button(localized("取消"), role: .cancel) { task?.cancel() }
                }.interfaceSectionSurface()
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.destructive)
                }.interfaceSectionSurface()
            }
        }
        .navigationTitle(localized("編輯遠端資料"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: save) {
                    Label(localized("儲存"), systemImage: "checkmark").labelStyle(.iconOnly)
                }.disabled(working || (capabilities.canEditMetadata ? title : filename).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (capabilities.canEditMetadata && author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func save() {
        guard !working else { return }
        working = true; errorMessage = nil
        task = Task { @MainActor in
            defer { working = false }
            do {
                let updated: RemoteLibraryItem
                if capabilities.canEditMetadata {
                    try await dependencies.remoteLibraryWriting.updateMetadata(item: item, title: title,
                        authors: author.isEmpty ? [] : [author], readingStore: store)
                    updated = RemoteLibraryItem(id: item.id, connectionID: item.connectionID, title: title,
                        author: author, summary: item.summary, coverURL: item.coverURL, formats: item.formats)
                } else {
                    let url = try await dependencies.remoteLibraryWriting.move(item: item, toName: filename, readingStore: store)
                    guard let original = item.formats.first else { throw RemoteLibraryError.unsupportedFormat }
                    updated = RemoteLibraryItem(id: url.absoluteString, connectionID: item.connectionID,
                        title: url.deletingPathExtension().lastPathComponent, author: item.author, summary: item.summary,
                        coverURL: item.coverURL, formats: [RemoteLibraryFormat(url: url, fileExtension: original.fileExtension,
                            mimeType: original.mimeType, size: original.size)])
                }
                onSaved(updated)
                UIAccessibility.post(notification: .announcement, argument: localized("遠端書庫已更新"))
                dismiss()
            } catch {
                errorMessage = Task.isCancelled ? localized("操作已取消，請重新整理書庫確認伺服器狀態") : error.localizedDescription
            }
        }
    }
}

struct CalibreProgressStatusView: View {
    let bookID: UUID
    @ObservedObject var service: CalibreProgressService

    var body: some View {
        Section(localized("Calibre 閱讀進度")) {
            switch service.state(for: bookID) {
            case .idle:
                Text(localized("閱讀時會回傳可精確對應的位置"))
                    .foregroundStyle(DSColor.textSecondary)
            case .syncing:
                ProgressView(localized("正在回傳閱讀進度"))
            case .synced:
                Label(localized("閱讀進度已回傳"), systemImage: "checkmark.circle")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.destructive)
                Button(localized("重新回傳進度")) { Task { await service.retry(bookID: bookID) } }
            }
        }
        .interfaceSectionSurface()
    }
}
