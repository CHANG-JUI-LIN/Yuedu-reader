import Foundation
import Combine

// MARK: - Log Model

enum DebugLevel: String {
    case info    = "info"
    case success = "success"
    case warning = "warning"
    case error   = "error"
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: DebugLevel
    let step: String
    let summary: String
    var detail: String?

    init(level: DebugLevel, step: String, summary: String, detail: String? = nil) {
        self.timestamp = Date()
        self.level = level
        self.step = step
        self.summary = summary
        self.detail = detail
    }
}

// MARK: - Engine

/// Wraps `ModernParserBridge` to provide structured, per-step debug logs
/// for all four parsing stages: search / bookInfo / TOC / content.
///
/// Designed to be used from `BookSourceRuleDebugView`.  Each run method
/// clears the log, executes the stage, and appends `DebugLogEntry` items
/// that the UI can display with timing and per-step input/output.
@MainActor
final class BookSourceDebugEngine: ObservableObject {

    @Published var logs: [DebugLogEntry] = []
    @Published var isRunning = false

    let source: BookSource
    private let bridge: ModernParserBridge

    init(source: BookSource) {
        self.source = source
        self.bridge = ModernParserBridge(source: source)
    }

    // MARK: - Public Run Methods

    func runSearch(keyword: String, page: Int = 1) async {
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else {
            appendLog(.warning, step: "搜索", summary: "關鍵字不能為空")
            return
        }
        logs.removeAll()
        isRunning = true
        defer { isRunning = false }

        appendLog(.info, step: "搜索", summary: "關鍵字: \(keyword)，頁碼: \(page)")
        appendLog(.info, step: "搜索 URL", summary: source.searchUrl)

        let t0 = Date()
        do {
            let books = try await bridge.searchBooks(keyword: keyword, page: page)
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(t0))
            if books.isEmpty {
                appendLog(.warning, step: "搜索結果", summary: "無結果（\(elapsed)）")
            } else {
                appendLog(.success, step: "搜索結果",
                          summary: "共 \(books.count) 本書（\(elapsed)）",
                          detail: books.prefix(5).map {
                              "📖 \($0.name) — \($0.author)\n    書源URL: \($0.bookUrl)"
                          }.joined(separator: "\n"))
                for book in books.prefix(10) {
                    appendLog(.info, step: "  書目",
                              summary: "《\(book.name)》 \(book.author)",
                              detail: "URL: \(book.bookUrl)\n介紹: \(book.intro.prefix(100))")
                }
            }
        } catch {
            appendLog(.error, step: "搜索失敗",
                      summary: error.localizedDescription)
        }
    }

    func runBookInfo(url: String) async {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else {
            appendLog(.warning, step: "詳情", summary: "URL 不能為空"); return
        }
        logs.removeAll()
        isRunning = true
        defer { isRunning = false }

        appendLog(.info, step: "詳情", summary: "URL: \(url)")

        let t0 = Date()
        do {
            let book = try await bridge.getBookInfo(url: url)
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(t0))
            appendLog(.success, step: "書籍詳情", summary: "《\(book.name)》（\(elapsed)）",
                      detail: """
                      書名: \(book.name)
                      作者: \(book.author)
                      封面: \(book.coverUrl)
                      簡介: \(book.intro.prefix(200))
                      目錄URL: \(book.tocUrl)
                      """)
        } catch {
            appendLog(.error, step: "詳情失敗", summary: error.localizedDescription)
        }
    }

    func runTOC(url: String) async {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else {
            appendLog(.warning, step: "目錄", summary: "URL 不能為空"); return
        }
        logs.removeAll()
        isRunning = true
        defer { isRunning = false }

        appendLog(.info, step: "目錄", summary: "URL: \(url)")

        let t0 = Date()
        do {
            let chapters = try await bridge.getChapterList(url: url)
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(t0))
            if chapters.isEmpty {
                appendLog(.warning, step: "目錄結果", summary: "無章節（\(elapsed)）")
            } else {
                appendLog(.success, step: "目錄結果",
                          summary: "共 \(chapters.count) 章（\(elapsed)）")
                for ch in chapters.prefix(20) {
                    let flags = [ch.isVolume ? "卷" : nil, ch.isVip ? "VIP" : nil, ch.isPay ? "付費" : nil]
                        .compactMap { $0 }.joined(separator: " ")
                    appendLog(.info, step: "  第 \(ch.index + 1) 章",
                              summary: ch.title + (flags.isEmpty ? "" : " [\(flags)]"),
                              detail: "URL: \(ch.url)")
                }
                if chapters.count > 20 {
                    appendLog(.info, step: "  …", summary: "還有 \(chapters.count - 20) 章（未顯示）")
                }
            }
        } catch {
            appendLog(.error, step: "目錄失敗", summary: error.localizedDescription)
        }
    }

    func runContent(url: String) async {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else {
            appendLog(.warning, step: "正文", summary: "URL 不能為空"); return
        }
        logs.removeAll()
        isRunning = true
        defer { isRunning = false }

        appendLog(.info, step: "正文", summary: "URL: \(url)")

        let t0 = Date()
        do {
            let content = try await bridge.getContent(url: url)
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(t0))
            if content.isEmpty {
                appendLog(.warning, step: "正文結果", summary: "空內容（\(elapsed)）")
            } else {
                appendLog(.success, step: "正文結果",
                          summary: "\(content.count) 字符（\(elapsed)）",
                          detail: String(content.prefix(500)))
            }
        } catch {
            appendLog(.error, step: "正文失敗", summary: error.localizedDescription)
        }
    }

    func clear() {
        logs.removeAll()
    }

    // MARK: - Private

    private func appendLog(_ level: DebugLevel, step: String, summary: String, detail: String? = nil) {
        logs.append(DebugLogEntry(level: level, step: step, summary: summary, detail: detail))
    }
}
