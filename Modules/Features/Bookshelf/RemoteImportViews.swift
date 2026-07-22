import SwiftUI

// MARK: - WebDAV Import

/// Browse a WebDAV server and import EPUB/TXT/Markdown files into the library.
/// Reuses the credentials configured in `WebDAVManager` (the same ones used by
/// WebDAV sync). When no server is configured the user is shown a small form.
struct WebDAVImportView: View {
    @EnvironmentObject var store: BookStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var webdav = WebDAVManager.shared
    @State private var isBrowsing = false

    private var client: WebDAVBrowseClient {
        WebDAVBrowseClient(serverUrl: webdav.serverUrl, username: webdav.username, password: webdav.password)
    }

    private var hasServer: Bool {
        !webdav.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isBrowsing, let root = client.rootURL {
                    WebDAVDirectoryView(client: client, folderURL: root, title: localized("從 WebDAV 匯入"))
                        .environmentObject(store)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button(localized("設定")) { isBrowsing = false }
                            }
                        }
                } else {
                    credentialsForm
                }
            }
            .navigationDestination(for: WebDAVBrowseClient.Entry.self) { entry in
                WebDAVDirectoryView(client: client, folderURL: entry.url, title: entry.name)
                    .environmentObject(store)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label(localized("取消"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("取消"))
                }
            }
        }
        .onAppear { if hasServer { isBrowsing = true } }
    }

    private var credentialsForm: some View {
        Form {
            Section(header: Text(localized("伺服器設定"))) {
                HStack {
                    Text(localized("網址")).foregroundColor(DSColor.textSecondary)
                    TextField("https://example.com/dav", text: $webdav.serverUrl)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }
                HStack {
                    Text(localized("帳號")).foregroundColor(DSColor.textSecondary)
                    TextField(localized("使用者名稱"), text: $webdav.username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text(localized("密碼")).foregroundColor(DSColor.textSecondary)
                    SecureField(localized("密碼"), text: $webdav.password)
                }
            }
            Section {
                Button {
                    isBrowsing = true
                } label: {
                    Label(localized("瀏覽檔案"), systemImage: "folder")
                        .foregroundColor(DSColor.accent)
                }
                .disabled(!hasServer)
            } footer: {
                Text(localized("WebDAV 匯入會沿用「WebDAV 同步」的伺服器設定。"))
            }
        }
        .navigationTitle(localized("從 WebDAV 匯入"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
    }
}

// MARK: - WebDAV Directory Browser

/// A single WebDAV collection rendered as a list. Folders push another instance
/// (via `navigationDestination` on the parent stack); importable files download
/// on tap and are handed to `BookStore`.
struct WebDAVDirectoryView: View {
    @EnvironmentObject var store: BookStore
    let client: WebDAVBrowseClient
    let folderURL: URL
    let title: String

    @State private var entries: [WebDAVBrowseClient.Entry] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var importingID: String?
    @State private var importedIDs: Set<String> = []
    @State private var failedID: String?

    var body: some View {
        List {
            if let loadError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundColor(DSColor.textSecondary)
                        Button(localized("重試")) { Task { await load() } }
                            .foregroundColor(DSColor.accent)
                    }
                    .padding(.vertical, 4)
                }
            }
            ForEach(entries) { entry in
                row(for: entry)
            }
        }
        .overlay {
            if isLoading && entries.isEmpty && loadError == nil {
                ProgressView().controlSize(.large)
            } else if !isLoading && entries.isEmpty && loadError == nil {
                ContentUnavailableView(
                    localized("此資料夾沒有可匯入的書籍"),
                    systemImage: "folder"
                )
            }
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .bookshelf)
        .task(id: folderURL) { await load() }
    }

    @ViewBuilder
    private func row(for entry: WebDAVBrowseClient.Entry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: entry) {
                Label(entry.name, systemImage: "folder.fill")
                    .foregroundColor(DSColor.textPrimary)
            }
        } else {
            Button {
                importEntry(entry)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon(for: entry))
                        .foregroundColor(entry.isImportableBook ? DSColor.accent : DSColor.textSecondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .foregroundColor(entry.isImportableBook ? DSColor.textPrimary : DSColor.textSecondary)
                        Text(sizeText(entry.size))
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    Spacer()
                    trailingStatus(for: entry)
                }
            }
            .disabled(!entry.isImportableBook || importingID != nil)
        }
    }

    @ViewBuilder
    private func trailingStatus(for entry: WebDAVBrowseClient.Entry) -> some View {
        if importingID == entry.id {
            ProgressView()
        } else if importedIDs.contains(entry.id) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        } else if failedID == entry.id {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
        } else if entry.isImportableBook {
            Image(systemName: "arrow.down.circle").foregroundColor(DSColor.accent)
        }
    }

    private func icon(for entry: WebDAVBrowseClient.Entry) -> String {
        switch entry.fileExtension {
        case "epub":            return "book.closed"
        case "txt", "md", "markdown": return "doc.text"
        default:                return "doc"
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func load() async {
        await MainActor.run {
            isLoading = true
            loadError = nil
        }
        do {
            let result = try await client.list(folderURL)
            await MainActor.run {
                self.entries = result
                self.isLoading = false
            }
        } catch {
            let message = (error as? WebDAVError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                self.loadError = message
                self.isLoading = false
            }
        }
    }

    private func importEntry(_ entry: WebDAVBrowseClient.Entry) {
        guard entry.isImportableBook, importingID == nil else { return }
        importingID = entry.id
        failedID = nil
        Task { @MainActor in
            do {
                let tempURL = try await client.download(entry)
                let bookTitle = (entry.name as NSString).deletingPathExtension
                switch entry.fileExtension {
                case "epub":
                    try await store.importEpub(url: tempURL, title: bookTitle)
                case "md", "markdown":
                    try store.importMarkdown(url: tempURL, title: bookTitle)
                default:
                    try await store.importTxt(url: tempURL, title: bookTitle)
                }
                try? FileManager.default.removeItem(at: tempURL)
                importedIDs.insert(entry.id)
                importingID = nil
            } catch {
                failedID = entry.id
                importingID = nil
            }
        }
    }
}
