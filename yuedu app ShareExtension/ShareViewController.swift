import UIKit
import Social
import UniformTypeIdentifiers
import MobileCoreServices

/// ShareExtension — imports Legado book-source JSON or plain book-source URL
/// shared from Safari / other apps into yuedu app.
class ShareViewController: UIViewController {

    private let appGroupID = "group.com.zruilin.yuedu-app"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        // Show a simple spinner while we process
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
              let providers = extensionItem.attachments else {
            finish(success: false, message: "無法讀取共享內容")
            return
        }

        // Priority 1: JSON file → book sources
        let jsonType = UTType.json.identifier
        if let jsonProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(jsonType) }) {
            jsonProvider.loadItem(forTypeIdentifier: jsonType, options: nil) { [weak self] item, error in
                DispatchQueue.main.async {
                    if let url = item as? URL {
                        self?.importJSON(from: url)
                    } else if let data = item as? Data {
                        self?.processJSONData(data)
                    } else {
                        self?.finish(success: false, message: "無法讀取 JSON 檔案")
                    }
                }
            }
            return
        }

        // Priority 2: URL → treat as book source URL to add
        let urlType = UTType.url.identifier
        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            urlProvider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] item, error in
                DispatchQueue.main.async {
                    if let url = item as? URL {
                        self?.importSourceURL(url.absoluteString)
                    } else {
                        self?.finish(success: false, message: "無法讀取 URL")
                    }
                }
            }
            return
        }

        // Priority 3: Plain text URL / JSON
        let textType = UTType.plainText.identifier
        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            textProvider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] item, error in
                DispatchQueue.main.async {
                    if let text = item as? String {
                        self?.processText(text)
                    } else {
                        self?.finish(success: false, message: "無法讀取文字內容")
                    }
                }
            }
            return
        }

        finish(success: false, message: "不支援的內容類型")
    }

    // MARK: - Import Handlers

    private func importJSON(from url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            finish(success: false, message: "無法讀取檔案")
            return
        }
        processJSONData(data)
    }

    private func processJSONData(_ data: Data) {
        // Store the raw JSON in App Group UserDefaults for the main app to import
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            finish(success: false, message: "App Group 未設定")
            return
        }

        // Validate: must be a JSON array
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              obj is [[String: Any]] else {
            finish(success: false, message: "不是有效的書源 JSON 格式")
            return
        }

        // Queue it for import by the main app
        var pending = defaults.array(forKey: "shared_book_sources_queue") as? [Data] ?? []
        pending.append(data)
        defaults.set(pending, forKey: "shared_book_sources_queue")

        finish(success: true, message: "書源已加入匯入佇列，請開啟閱讀 App 完成匯入")
    }

    private func importSourceURL(_ urlString: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            finish(success: false, message: "App Group 未設定")
            return
        }
        var pending = defaults.array(forKey: "shared_source_urls_queue") as? [String] ?? []
        pending.append(urlString)
        defaults.set(pending, forKey: "shared_source_urls_queue")
        finish(success: true, message: "書源連結已儲存，請開啟閱讀 App 完成匯入")
    }

    private func processText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http"), let _ = URL(string: trimmed) {
            importSourceURL(trimmed)
        } else if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8) {
            processJSONData(data)
        } else {
            finish(success: false, message: "無法識別的格式")
        }
    }

    // MARK: - Completion

    private func finish(success: Bool, message: String) {
        // Show result briefly then close
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
