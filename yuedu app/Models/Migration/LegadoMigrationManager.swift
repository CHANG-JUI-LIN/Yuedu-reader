import Foundation
import Combine

// MARK: - Private Legado Book struct (intermediate decode target)

private struct LegadoBook: Codable {
    var name: String?
    var author: String?
    var origin: String?       // book source URL (matches BookSource.bookSourceUrl)
    var originName: String?   // book source name
    var coverUrl: String?
    var intro: String?
    var kind: String?
    var totalChapterNum: Int?
    var latestChapterTitle: String?
    var bookUrl: String?       // canonical book detail page URL
}

// MARK: - Migration Manager

class LegadoMigrationManager: ObservableObject {
    static let shared = LegadoMigrationManager()

    @Published var isImporting: Bool = false
    @Published var progress: Double = 0       // 0.0 – 1.0
    @Published var statusLog: [String] = []
    @Published var importResult: ImportResult? = nil

    struct ImportResult {
        var sourcesImported: Int
        var booksImported: Int
        var errors: [String]
    }

    private init() {}

    // MARK: - Book Sources
    // BookSource.swift already has a full Legado-compatible decoder, so we
    // delegate straight to BookSourceStore.importFromJSON which handles
    // arrays, single objects, and the backup-wrapper {"bookSources":[...]} format.

    func importBookSources(from data: Data) async -> Int {
        guard let jsonString = String(data: data, encoding: .utf8) else {
            appendLog("❌ 無法將資料轉為字串")
            return 0
        }
        do {
            let count = try BookSourceStore.shared.importFromJSON(jsonString)
            return count
        } catch {
            appendLog("❌ 書源匯入失敗：\(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Books

    func importBooks(from data: Data, into bookStore: BookStore) async -> Int {
        guard let legadoBooks = try? JSONDecoder().decode([LegadoBook].self, from: data) else {
            appendLog("❌ 無法解析書籍列表")
            return 0
        }

        var count = 0
        count = await MainActor.run { () -> Int in
            var importCount = 0
            for book in legadoBooks {
                let title  = book.name   ?? "未知書名"
                let author = book.author ?? "未知作者"
                let bookDetailURL = book.bookUrl ?? book.origin ?? ""

                // If we have a matching local book source, attach to it; otherwise
                // fall back to a browser-browsed entry (no specific source required).
                let matchedSource = BookSourceStore.shared.sources.first {
                    $0.bookSourceUrl == book.origin
                }

                if let source = matchedSource, !bookDetailURL.isEmpty {
                    _ = bookStore.addOnlineBook(
                        name: title,
                        author: author,
                        sourceId: source.id,
                        bookInfoURL: bookDetailURL,
                        tocURL: nil,
                        runtimeVariables: nil,
                        chapters: []
                    )
                } else {
                    // Use a stable placeholder URL when no real URL is available so
                    // the book doesn't end up with an empty source string.
                    let fallbackURL = bookDetailURL.isEmpty
                        ? "legado://import/\(UUID().uuidString)"
                        : bookDetailURL
                    _ = bookStore.addWebBrowsedBook(
                        name: title,
                        author: author,
                        sourceURL: fallbackURL,
                        chapters: []
                    )
                }
                importCount += 1
            }
            return importCount
        }
        return count
    }

    // MARK: - Auto-detect and import

    func importFromJSON(data: Data, bookStore: BookStore) async {
        await MainActor.run {
            isImporting  = true
            progress     = 0
            importResult = nil
        }

        var sourcesImported = 0
        var booksImported   = 0
        var errors: [String] = []

        appendLog("🔍 正在分析 JSON 格式…")

        switch detectFormat(data: data) {
        case .bookSources:
            appendLog("📚 偵測到書源格式，開始匯入…")
            await MainActor.run { progress = 0.3 }
            sourcesImported = await importBookSources(from: data)
            appendLog("✅ 書源匯入完成：\(sourcesImported) 個")

        case .books:
            appendLog("📖 偵測到書籍格式，開始匯入…")
            await MainActor.run { progress = 0.3 }
            booksImported = await importBooks(from: data, into: bookStore)
            appendLog("✅ 書籍匯入完成：\(booksImported) 本")

        case .unknown:
            // Try book sources first (richer format detection), then books.
            appendLog("⚠️ 格式不明，嘗試書源解析…")
            await MainActor.run { progress = 0.2 }
            sourcesImported = await importBookSources(from: data)
            if sourcesImported == 0 {
                appendLog("⚠️ 書源解析無結果，嘗試書籍解析…")
                await MainActor.run { progress = 0.5 }
                booksImported = await importBooks(from: data, into: bookStore)
            }
            if sourcesImported == 0 && booksImported == 0 {
                let msg = "無法識別 JSON 格式，請確認為 Legado 書源或書籍匯出檔"
                errors.append(msg)
                appendLog("❌ \(msg)")
            }
        }

        let finalSourcesImported = sourcesImported
        let finalBooksImported   = booksImported
        let finalErrors          = errors
        await MainActor.run {
            progress     = 1.0
            importResult = ImportResult(
                sourcesImported: finalSourcesImported,
                booksImported:   finalBooksImported,
                errors:          finalErrors
            )
            isImporting = false
        }
    }

    // MARK: - Helpers

    func appendLog(_ message: String) {
        DispatchQueue.main.async {
            self.statusLog.append(message)
            // Keep log bounded to avoid unbounded memory growth.
            if self.statusLog.count > 200 { self.statusLog.removeFirst() }
        }
    }

    // MARK: - Format detection

    private enum FormatKind { case bookSources, books, unknown }

    private func detectFormat(data: Data) -> FormatKind {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return .unknown }

        // Single object: check top-level keys.
        if let dict = obj as? [String: Any] {
            if dict["bookSourceUrl"] != nil    { return .bookSources }
            if dict["bookSources"]   != nil    { return .bookSources }
            if dict["name"]          != nil    { return .books }
            return .unknown
        }

        // Array: inspect the first element.
        if let arr = obj as? [[String: Any]], let first = arr.first {
            if first["bookSourceUrl"] != nil                  { return .bookSources }
            if first["name"] != nil || first["author"] != nil { return .books }
        }

        return .unknown
    }
}
