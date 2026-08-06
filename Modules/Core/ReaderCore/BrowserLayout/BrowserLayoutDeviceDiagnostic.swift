import Foundation
import UIKit

/// On-device coordinate diagnostics for the browser-layout engine.
///
/// DEBUG-only: every log is compiled out in Release. Logs never carry book
/// titles, chapter text, URLs, or image data — only geometry, mode, and
/// identifiers. The prefix lets Xcode Console filter precisely:
///
///     🔬 BROWSER_DEVICE
///
/// A single chapter layout+display share ONE traceID (generated when the
/// engine begins laying out the chapter) so every log line can be chained.
/// Rate limiting: each (stage, spine, generation) key logs at most once per
/// process — no redraw spam.
enum BrowserLayoutDeviceDiagnostic {

    static let prefix = "🔬 BROWSER_DEVICE"

    /// Which (stage, spine, generation) has already logged its full payload.
    /// Guarantees each stage prints exactly once per generation.
    enum DiagnosticKey: Hashable {
        case launch
        case engineCreated(spine: Int, generation: Int)
        case engineDecision(spine: Int, generation: Int)
        case chapterConfig(spine: Int, generation: Int)
        case k1k2Layout(spine: Int, generation: Int)
        case k1Fragment(spine: Int, generation: Int)
        case k1DisplayList(spine: Int, generation: Int)
        case pageViewConfigure(spine: Int, generation: Int)
        case pageViewDidMoveToWindow(spine: Int, generation: Int)
        case pageViewLayout(spine: Int, generation: Int)
        case pageViewDraw(spine: Int, generation: Int)
        case superviewChain(spine: Int, generation: Int)
    }

    static var loggedKeys = Set<DiagnosticKey>()

    /// traceID per (spine, generation): the engine assigns it when the chapter
    /// layout starts; PageView/DisplayList reuse it via `BrowserLayoutPageView.debugSpec`.
    private static var traceIDs: [String: String] = [:]
    private static var traceIDLock = NSLock()

    static func newTraceID(for spine: Int, generation: Int) -> String {
        let id = String(UUID().uuidString.prefix(8))
        traceIDLock.lock()
        traceIDs[key(spine: spine, generation: generation)] = id
        traceIDLock.unlock()
        return id
    }

    static func traceID(for spine: Int, generation: Int) -> String {
        traceIDLock.lock()
        let id = traceIDs[key(spine: spine, generation: generation)] ?? "unknown"
        traceIDLock.unlock()
        return id
    }

    private static func key(spine: Int, generation: Int) -> String {
        "\(spine):\(generation)"
    }

    /// Logs one line with the standard envelope. Rate-limited per key.
    static func log(
        _ key: DiagnosticKey,
        spine: Int,
        generation: Int,
        page: Int = -1,
        message: String
    ) {
        #if DEBUG
        guard loggedKeys.insert(key).inserted else { return }
        let tid = traceID(for: spine, generation: generation)
        let thread = Thread.isMainThread ? "main" : "bg"
        let pagePart = page >= 0 ? " page=\(page)" : ""
        print("\(prefix) trace=\(tid) gen=\(generation) spine=\(spine)\(pagePart) thread=\(thread) \(message)")
        #endif
    }

    /// Unthrottled one-liner (summary for non-target pages).
    static func summary(_ message: String) {
        #if DEBUG
        print("\(prefix) \(message)")
        #endif
    }

    /// Format a CGRect with its coordinate space, so a bare rect is never
    /// logged without context.
    static func rect(_ rect: CGRect, space: String) -> String {
        "\(space) rect=(x:\(String(format: "%.2f", rect.minX)), y:\(String(format: "%.2f", rect.minY)), w:\(String(format: "%.2f", rect.width)), h:\(String(format: "%.2f", rect.height)))"
    }

    /// Current build identity for the launch banner.
    static var commitSHA: String {
        #if DEBUG
        // 1) -commit-sha launch argument (UI test / driver passes git rev-parse).
        if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-commit-sha"),
           ProcessInfo.processInfo.arguments.indices.contains(idx + 1) {
            return String(ProcessInfo.processInfo.arguments[idx + 1].prefix(7))
        }
        // 2) Info.plist GitCommitSHA injected by a build phase when present.
        if let sha = Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String, !sha.isEmpty {
            return String(sha.prefix(7))
        }
        return "no-sha-injected"
        #else
        return "release"
        #endif
    }

    static var buildDate: String {
        #if DEBUG
        if let url = Bundle.main.executableURL,
           let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return fmt.string(from: date)
        }
        return "unknown"
        #else
        return "release"
        #endif
    }

    /// Transforms a CGContext's CTM into a compact string.
    static func ctm(_ context: CGContext) -> String {
        let t = context.ctm
        return String(format: "a=%.4f b=%.4f c=%.4f d=%.4f tx=%.2f ty=%.2f", t.a, t.b, t.c, t.d, t.tx, t.ty)
    }
}
