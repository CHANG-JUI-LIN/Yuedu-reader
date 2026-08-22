import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Removes credentials from a diagnostic line before it can leave the device.
///
/// The rules are deliberately blunt — over-redacting a log costs a little context,
/// under-redacting it hands someone's account to whoever receives the file. The
/// query-string rule is the load-bearing one and is not a guess: `SourceAPIErrorLog`
/// already strips queries for the same reason, documented there as "these APIs carry
/// the user's token in it".
///
/// This does **not** try to remove book titles or source hostnames. Those are
/// frequently the entire content of the bug ("this source stopped working"), and the
/// export is a plain-text file the user reads and chooses a destination for. The
/// screen says so in as many words.
enum DiagnosticRedactor {

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = {
        let specs: [(String, String)] = [
            // Everything after `?` in a URL. Tokens, session ids and invite codes all
            // ride there in this app's book-source APIs.
            (#"(https?://[^\s"'<>]+?)\?[^\s"'<>]*"#, "$1?<redacted>"),
            // `Bearer abc123`
            (#"(?i)\bBearer\s+[A-Za-z0-9._\-~+/=]+"#, "Bearer <redacted>"),
            // Quoted JSON values need their own rule. The generic key/value rules
            // below deliberately stop at punctuation, which used to leave a real
            // `"cookie":"a=b; c=d"` value untouched in exported source context.
            (#"(?i)"(cookie|set-cookie|authorization|access[_-]?token|refresh[_-]?token|id[_-]?token|token|api[_-]?key|apikey|secret|password|passwd|pwd|session[_-]?id)"\s*:\s*"[^"]*""#,
             #""$1":"<redacted>""#),
            // Header-ish and JSON-ish `key: value` / `key=value` pairs.
            (#"(?i)\b(cookie|set-cookie|authorization)\b\s*[:=]\s*[^\s,;}]+"#, "$1=<redacted>"),
            (#"(?i)\b(access[_-]?token|refresh[_-]?token|id[_-]?token|token|api[_-]?key|apikey|secret|password|passwd|pwd|session[_-]?id)\b"#
             + #"\s*["']?\s*[:=]\s*["']?[^\s,;}"']+"#, "$1=<redacted>"),
        ]
        return specs.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(regex: regex, template: template)
        }
    }()

    static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }
}

/// The plain-text report handed to `ShareLink`.
///
/// `ShareLink` rather than `.fileExporter` so the system share sheet owns file
/// destinations. The link itself must remain a direct page control: on iOS 17,
/// launching even a share sheet from a still-dismissing SwiftUI `Menu` can be lost.
///
/// Holds the entries and renders on demand. `Menu` content is built eagerly with its
/// parent, so formatting several thousand lines at construction time would run on
/// every layout pass of the screen.
struct DiagnosticReportBundle: Transferable {
    let filename: String
    let entries: [DiagnosticEntry]
    let session: DiagnosticSession
    let uncleanSessions: [DiagnosticSession]

    static var transferRepresentation: some TransferRepresentation {
        // `.data`, not `.plainText`, and this is the whole reason the export works.
        //
        // `public.plain-text` conforms to `public.text`, so a share target that accepts
        // text — QQ, WeChat, Messages — asks the item provider for the *string* instead
        // of the file, then chops it into one message per chunk. A 3 MB log arrives as
        // several hundred messages. Advertising only `public.data` leaves a receiver no
        // text representation to take, so it has to accept the file. The name still ends
        // in `.txt`, so saving it and opening it are unchanged.
        FileRepresentation(exportedContentType: .data) { bundle in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(bundle.filename)
            try Data(bundle.render().utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    static func filename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "yuedu-diagnostics-\(formatter.string(from: now)).txt"
    }

    private static let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    func render() -> String {
        var out: [String] = []

        out.append("Yuedu Reader diagnostics")
        out.append("app=\(session.appVersion) (\(session.build))")
        out.append("device=\(session.deviceModel)  os=\(session.osVersion)")
        out.append("session=\(session.id.uuidString)  started=\(Self.lineFormatter.string(from: session.startedAt))")
        out.append("exported=\(Self.lineFormatter.string(from: Date()))")
        out.append("")

        let reportable = entries.filter { $0.severity.isReportable }
        out.append("--- summary ---")
        out.append("entries=\(entries.count)  reportable=\(reportable.count)")
        if !uncleanSessions.isEmpty {
            out.append("previous sessions that ended abnormally: \(uncleanSessions.count)")
            for session in uncleanSessions {
                out.append("  \(Self.lineFormatter.string(from: session.startedAt))  app=\(session.appVersion) (\(session.build))  device=\(session.deviceModel)")
            }
        }
        out.append("")

        if !reportable.isEmpty {
            // Repeated ahead of the full log: this is what someone triaging the report
            // needs, and it should not require scrolling past 6000 trace lines.
            out.append("--- anomalies and faults ---")
            for entry in reportable.sorted(by: { $0.sequence < $1.sequence }) {
                out.append(contentsOf: Self.format(entry))
            }
            out.append("")
        }

        out.append("--- full log (oldest first) ---")
        for entry in entries.sorted(by: { $0.sequence < $1.sequence }) {
            out.append(contentsOf: Self.format(entry))
        }

        // The log has now left the device, so the banner should stop asking for it.
        // Done here rather than at the button because both routes out — the ShareLink
        // file representation and 複製全部 — go through `render()`.
        if let highest = entries.map(\.sequence).max() {
            DiagnosticLog.shared.acknowledgeReported(through: highest)
        }

        return DiagnosticRedactor.redact(out.joined(separator: "\n"))
    }

    private static func format(_ entry: DiagnosticEntry) -> [String] {
        var lines = [
            "\(lineFormatter.string(from: entry.timestamp)) \(entry.severity.exportTag) [\(entry.category.rawValue)] \(entry.message)"
        ]
        if let detail = entry.detail, !detail.isEmpty {
            lines.append(contentsOf: detail.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" })
        }
        return lines
    }
}
