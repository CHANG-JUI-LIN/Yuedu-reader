import UIKit
import Social
import UniformTypeIdentifiers

/// ShareExtension — queues shared files / URLs for the main app.
///
/// The extension deliberately does not decide "book source vs RSS vs local book"
/// beyond lightweight storage hints. The main app owns the import stores and
/// performs the final format classification when `SharedImportQueueDrainer`
/// drains `shared_import_items_queue`.
class ShareViewController: UIViewController {

    private let appGroupID = "group.com.zhangruilin.yuedureader"
    private let payloadQueueKey = "shared_import_items_queue"
    private let payloadDirectoryName = "shared_import_payloads"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        handleSharedItems()
    }

    // MARK: - Share Handling

    private func handleSharedItems() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = extensionItem.attachments,
              let provider = providers.first else {
            finish(success: false, message: "無法讀取共享內容")
            return
        }

        if loadFileURL(from: provider) { return }
        if loadRemoteURL(from: provider) { return }
        if loadKnownFileRepresentation(from: provider) { return }
        if loadPlainText(from: provider) { return }

        finish(success: false, message: "不支援的內容類型")
    }

    private func loadFileURL(from provider: NSItemProvider) -> Bool {
        let typeIdentifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return false }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取檔案：\(error.localizedDescription)")
                }
                return
            }
            guard let url = item as? URL, url.isFileURL else {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取檔案")
                }
                return
            }
            self.enqueueFile(at: url, suggestedName: provider.suggestedName, typeIdentifier: typeIdentifier)
        }
        return true
    }

    private func loadKnownFileRepresentation(from provider: NSItemProvider) -> Bool {
        guard let typeIdentifier = knownFileTypeIdentifiers.first(where: {
            provider.hasItemConformingToTypeIdentifier($0)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取檔案：\(error.localizedDescription)")
                }
                return
            }

            if let url = item as? URL {
                self.enqueueFile(at: url, suggestedName: provider.suggestedName, typeIdentifier: typeIdentifier)
            } else if let data = item as? Data {
                self.enqueueData(data, suggestedName: provider.suggestedName, typeIdentifier: typeIdentifier)
            } else if let text = item as? String {
                self.processText(text)
            } else {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取檔案")
                }
            }
        }
        return true
    }

    private func loadRemoteURL(from provider: NSItemProvider) -> Bool {
        let typeIdentifier = UTType.url.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return false }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取 URL：\(error.localizedDescription)")
                }
                return
            }
            guard let url = item as? URL else {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取 URL")
                }
                return
            }

            if url.isFileURL {
                self.enqueueFile(at: url, suggestedName: provider.suggestedName, typeIdentifier: typeIdentifier)
            } else {
                self.enqueueRemoteURL(url.absoluteString, suggestedName: provider.suggestedName)
            }
        }
        return true
    }

    private func loadPlainText(from provider: NSItemProvider) -> Bool {
        let typeIdentifier = UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return false }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取文字：\(error.localizedDescription)")
                }
                return
            }
            guard let text = item as? String else {
                DispatchQueue.main.async {
                    self.finish(success: false, message: "無法讀取文字內容")
                }
                return
            }
            self.processText(text)
        }
        return true
    }

    private var knownFileTypeIdentifiers: [String] {
        [
            UTType(filenameExtension: "epub")?.identifier,
            UTType.json.identifier,
            UTType.xml.identifier,
            UTType.plainText.identifier,
            UTType.data.identifier,
            UTType(filenameExtension: "zip")?.identifier,
            UTType.audio.identifier,
            UTType.mpeg4Audio.identifier,
            UTType(filenameExtension: "txt")?.identifier,
            UTType(filenameExtension: "md")?.identifier,
            UTType(filenameExtension: "markdown")?.identifier,
            UTType(filenameExtension: "opml")?.identifier,
            UTType(filenameExtension: "cbz")?.identifier,
            UTType(filenameExtension: "yds")?.identifier,
            UTType(filenameExtension: "xbs")?.identifier,
            UTType(filenameExtension: "mrs")?.identifier,
            UTType(filenameExtension: "mp3")?.identifier,
            UTType(filenameExtension: "m4a")?.identifier,
            UTType(filenameExtension: "m4b")?.identifier,
            UTType(filenameExtension: "aac")?.identifier,
            UTType(filenameExtension: "flac")?.identifier,
            UTType(filenameExtension: "wav")?.identifier
        ].compactMap { $0 }
    }

    // MARK: - Queue Writers

    private func enqueueFile(at url: URL, suggestedName: String?, typeIdentifier: String?) {
        do {
            let destination = try copyIntoAppGroup(url: url, suggestedName: suggestedName, typeIdentifier: typeIdentifier)
            let payload = QueuedPayload(
                storageKind: .file,
                relativePath: destination.lastPathComponent,
                suggestedFilename: suggestedName ?? url.lastPathComponent,
                typeIdentifier: typeIdentifier
            )
            try append(payload)
            DispatchQueue.main.async {
                self.finish(success: true, message: "已加入匯入佇列，請開啟閱讀 App 完成匯入")
            }
        } catch {
            DispatchQueue.main.async {
                self.finish(success: false, message: "儲存共享檔案失敗：\(error.localizedDescription)")
            }
        }
    }

    private func enqueueData(_ data: Data, suggestedName: String?, typeIdentifier: String?) {
        do {
            let destination = try writeDataIntoAppGroup(data, suggestedName: suggestedName, typeIdentifier: typeIdentifier)
            let payload = QueuedPayload(
                storageKind: .file,
                relativePath: destination.lastPathComponent,
                suggestedFilename: suggestedName ?? destination.lastPathComponent,
                typeIdentifier: typeIdentifier
            )
            try append(payload)
            DispatchQueue.main.async {
                self.finish(success: true, message: "已加入匯入佇列，請開啟閱讀 App 完成匯入")
            }
        } catch {
            DispatchQueue.main.async {
                self.finish(success: false, message: "儲存共享資料失敗：\(error.localizedDescription)")
            }
        }
    }

    private func enqueueRemoteURL(_ urlString: String, suggestedName: String?) {
        do {
            let payload = QueuedPayload(
                storageKind: .remoteURL,
                remoteURLString: urlString,
                suggestedFilename: suggestedName ?? URL(string: urlString)?.lastPathComponent
            )
            try append(payload)
            DispatchQueue.main.async {
                self.finish(success: true, message: "連結已加入匯入佇列，請開啟閱讀 App 完成匯入")
            }
        } catch {
            DispatchQueue.main.async {
                self.finish(success: false, message: "儲存共享連結失敗：\(error.localizedDescription)")
            }
        }
    }

    private func processText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            enqueueRemoteURL(trimmed, suggestedName: nil)
            return
        }

        let data = Data(trimmed.utf8)
        enqueueData(data, suggestedName: guessedTextFilename(for: trimmed), typeIdentifier: UTType.plainText.identifier)
    }

    private func append(_ payload: QueuedPayload) throws {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            throw QueueError.appGroupUnavailable
        }
        let encoded = try JSONEncoder().encode(payload)
        var pending = defaults.array(forKey: payloadQueueKey) as? [Data] ?? []
        pending.append(encoded)
        defaults.set(pending, forKey: payloadQueueKey)
        defaults.synchronize()
    }

    private func copyIntoAppGroup(url: URL, suggestedName: String?, typeIdentifier: String?) throws -> URL {
        let destination = try destinationURL(suggestedName: suggestedName ?? url.lastPathComponent, typeIdentifier: typeIdentifier)
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func writeDataIntoAppGroup(_ data: Data, suggestedName: String?, typeIdentifier: String?) throws -> URL {
        let destination = try destinationURL(suggestedName: suggestedName, typeIdentifier: typeIdentifier)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func destinationURL(suggestedName: String?, typeIdentifier: String?) throws -> URL {
        guard let baseURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(payloadDirectoryName, isDirectory: true) else {
            throw QueueError.appGroupUnavailable
        }
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let ext = filenameExtension(suggestedName: suggestedName, typeIdentifier: typeIdentifier)
        let filename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        return baseURL.appendingPathComponent(filename)
    }

    private func filenameExtension(suggestedName: String?, typeIdentifier: String?) -> String {
        if let suggestedName {
            let ext = (suggestedName as NSString).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }
        if let typeIdentifier,
           let preferred = UTType(typeIdentifier)?.preferredFilenameExtension {
            return preferred.lowercased()
        }
        return "txt"
    }

    private func guessedTextFilename(for text: String) -> String {
        let lower = text.prefix(2048).lowercased()
        if lower.contains("<opml") {
            return "shared.opml"
        }
        if text.first(where: { !$0.isWhitespace }).map({ $0 == "{" || $0 == "[" }) == true,
           isValidJSONText(text) {
            return "shared.json"
        }
        return "shared.txt"
    }

    private func isValidJSONText(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    // MARK: - Completion

    private func finish(success: Bool, message: String) {
        let alert = UIAlertController(
            title: success ? "✓ 成功" : "✗ 失敗",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "關閉", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        present(alert, animated: true)
    }
}

private enum QueueError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group 未設定"
        }
    }
}

private enum StorageKind: String, Codable {
    case file
    case remoteURL
}

private struct QueuedPayload: Codable {
    var id = UUID().uuidString
    var storageKind: StorageKind
    var relativePath: String?
    var remoteURLString: String?
    var suggestedFilename: String?
    var typeIdentifier: String?
    var createdAt = Date()
}
