import Foundation
import Combine

// MARK: - Log Model

enum DebugLevel: String {
    case info    = "info"
    case success = "success"
    case warning = "warning"
    case error   = "error"
    case pipeline = "pipeline"   // granular per-rule steps
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
        defer {
            isRunning = false
            bridge.debugObserver = nil
        }

        attachObserver(stage: "搜索")
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
        defer {
            isRunning = false
            bridge.debugObserver = nil
        }

        attachObserver(stage: "詳情")
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
        defer {
            isRunning = false
            bridge.debugObserver = nil
        }

        attachObserver(stage: "目錄")
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
        defer {
            isRunning = false
            bridge.debugObserver = nil
        }

        attachObserver(stage: "正文")
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

    /// Export the current pipeline logs as a plain-text file in legadoStyleLog format,
    /// suitable for piping into `scripts/normalize_log.py --side ios` and then
    /// `scripts/compare_logs.py` for diff-driven comparison against Android logs.
    ///
    /// Returns the file URL. Saved to the app's temporary directory.
    @discardableResult
    func exportLogsAsText() -> URL {
        let lines = logs.map { entry -> String in
            var line = "\(entry.step): \(entry.summary)"
            if let detail = entry.detail {
                line += "\n" + detail.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
            }
            return line
        }.joined(separator: "\n")

        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "yuedu_pipeline_\(ts).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? lines.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Private

    /// Attaches the pipeline observer to `bridge` before each stage run.
    /// Events arrive on whatever thread the engine runs on, so we hop to
    /// `MainActor` before mutating `logs`.
    private func attachObserver(stage: String) {
        bridge.debugObserver = { [weak self] event in
            let entry = Self.debugEntry(for: event, stage: stage)
            Task { @MainActor [weak self] in
                self?.logs.append(entry)
            }
        }
    }

    private func appendLog(_ level: DebugLevel, step: String, summary: String, detail: String? = nil) {
        logs.append(DebugLogEntry(level: level, step: step, summary: summary, detail: detail))
    }

    // MARK: - RuleDebugEvent → DebugLogEntry

    private static func debugEntry(for event: RuleDebugEvent, stage: String) -> DebugLogEntry {
        let log = event.legadoStyleLog
        // Classify by event type
        let level: DebugLevel
        let step: String
        let summary: String
        var detail: String?

        switch event {
        case .contentSet(let type, let length, let preview, _):
            level = .info
            step = "[\(stage)] 原始數據"
            summary = "類型: \(type)  長度: \(length)字符"
            detail = preview.isEmpty ? nil : preview

        case .rulesParsed(let ruleStr, let segments):
            level = .pipeline
            step = "[\(stage)] 規則解析"
            summary = "規則: \(String(ruleStr.prefix(60)))"
            detail = segments.map { s in
                "  [\(s.index)] mode=\(s.mode)  rule=\(String(s.rule.prefix(60)))"
                + (s.replacePattern.isEmpty ? "" : "  ##\(s.replacePattern)")
            }.joined(separator: "\n")

        case .beforeExtract(let idx, let mode, let qualifiedRule, _):
            level = .pipeline
            step = "[\(stage)] 提取 #\(idx)"
            summary = "[\(mode)] \(String(qualifiedRule.prefix(80)))"
            detail = nil

        case .afterExtractValue(let idx, let result):
            level = result.isEmpty ? .warning : .pipeline
            step = "[\(stage)] 提取結果 #\(idx)"
            summary = result.isEmpty ? "（空）" : String(result.prefix(120))
            detail = result.count > 120 ? result : nil

        case .afterExtractList(let idx, let count, let items):
            level = count == 0 ? .warning : .pipeline
            step = "[\(stage)] 提取列表 #\(idx)"
            summary = "共 \(count) 項"
            detail = items.enumerated().map { "  [\($0)] \($1)" }.joined(separator: "\n")

        case .regexApplied(let idx, let pattern, let replacement, let before, let after):
            level = .pipeline
            step = "[\(stage)] 正則替換 #\(idx)"
            summary = "##\(String(pattern.prefix(40)))##\(String(replacement.prefix(20)))"
            detail = "前: \(String(before.prefix(100)))\n後: \(String(after.prefix(100)))"

        case .jsExecuted(let idx, _, _, let result):
            level = .pipeline
            step = "[\(stage)] JS執行 #\(idx)"
            summary = result.isEmpty ? "（空結果）" : String(result.prefix(120))
            detail = log

        case .extractionError(let idx, let mode, _, let error):
            level = .error
            step = "[\(stage)] 提取錯誤 #\(idx)"
            summary = "[\(mode)] \(error)"
            detail = nil

        case .finalResult(let value, let ms):
            level = value.isEmpty ? .warning : .success
            step = "[\(stage)] 最終值"
            summary = (value.isEmpty ? "（空）" : String(value.prefix(120)))
                + String(format: "  (%.1fms)", ms)
            detail = value.count > 120 ? value : nil

        case .finalResultList(let values, let ms):
            level = values.isEmpty ? .warning : .success
            step = "[\(stage)] 最終列表"
            summary = "共 \(values.count) 項" + String(format: "  (%.1fms)", ms)
            detail = values.prefix(20).enumerated().map { "  [\($0)] \($1)" }.joined(separator: "\n")
        }

        return DebugLogEntry(level: level, step: step, summary: summary, detail: detail)
    }
}
