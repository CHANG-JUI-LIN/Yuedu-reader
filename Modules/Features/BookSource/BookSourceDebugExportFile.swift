import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The 書源除錯大師 log handed to `ShareLink`.
///
/// Same shape as `DiagnosticReportBundle`: holds the entries and renders only when a
/// share actually completes. This view's body re-runs on every appended log entry, so
/// a pre-formatted `String` would re-format hundreds of entries on each one.
///
/// The link that shares this must stay a direct page control — see
/// `MenuShareLinkPresentationPolicy` for why it cannot live inside the toolbar `Menu`.
struct BookSourceDebugExportFile: Transferable {
    let filename: String
    let entries: [WebCrawlerDebugger.LogEntry]

    static var transferRepresentation: some TransferRepresentation {
        // `.data`, not `.plainText`, and this is the whole reason the export works.
        //
        // `public.plain-text` conforms to `public.text`, so a share target that accepts
        // text — QQ, WeChat, Messages — asks the item provider for the *string* instead
        // of the file, then chops it into one message per chunk. A 3 MB log arrives as
        // several hundred messages. Advertising only `public.data` leaves a receiver no
        // text representation to take, so it has to accept the file. The name still ends
        // in `.txt`, so saving it and opening it are unchanged.
        FileRepresentation(exportedContentType: .data) { file in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(file.filename)
            try Data(file.render().utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    /// Static because the 操作 section re-evaluates on every appended log entry, and a
    /// fresh `DateFormatter` per entry is pure churn while a source is being traced.
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func filename(now: Date = Date()) -> String {
        "yuedu-booksource-debug-\(filenameFormatter.string(from: now)).txt"
    }

    func render() -> String {
        Self.render(entries: entries)
    }

    /// Shared by the share sheet and 複製全部 so the two exports never drift.
    static func render(entries: [WebCrawlerDebugger.LogEntry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        let body = entries.map { entry -> String in
            var line = "\(formatter.string(from: entry.timestamp)) [\(entry.type.rawValue)] \(entry.message)"
            if let url = entry.url { line += "\n    url: \(url)" }
            switch entry.detail {
            case .headers(let headers):
                line += headers.sorted { $0.key < $1.key }
                    .map { "\n    \($0.key): \($0.value)" }.joined()
            case .body(let text), .text(let text):
                line += "\n" + text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    \($0)" }.joined(separator: "\n")
            case .none:
                break
            }
            return line
        }.joined(separator: "\n")
        // Book-source requests carry tokens in the query string and in headers, and
        // this text is about to leave the device.
        return DiagnosticRedactor.redact(body)
    }
}
