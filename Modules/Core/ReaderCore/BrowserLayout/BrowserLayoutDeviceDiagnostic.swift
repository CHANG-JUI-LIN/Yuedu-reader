import Foundation
import OSLog
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
        Self.logger.log("\(prefix) trace=\(tid) gen=\(generation) spine=\(spine)\(pagePart) thread=\(thread) \(message)")
        #endif
    }

    /// Unthrottled one-liner (summary for non-target pages).
    static func summary(_ message: String) {
        #if DEBUG
        Self.logger.log("\(prefix) \(message)")
        #endif
    }

    /// os_log destination: visible in Xcode Console, `log stream` and
    /// `simctl spawn log show` on simulator AND device — the previous `print`
    /// only reached an attached Xcode console.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "yuedu",
        category: "browser-layout-device"
    )

    /// Format a CGRect with its coordinate space, so a bare rect is never
    /// logged without context.
    static func rect(_ rect: CGRect, space: String) -> String {
        "\(space) rect=(x:\(String(format: "%.2f", rect.minX)), y:\(String(format: "%.2f", rect.minY)), w:\(String(format: "%.2f", rect.width)), h:\(String(format: "%.2f", rect.height)))"
    }

    /// Current build identity for the launch banner.
    static var commitSHA: String {
        #if DEBUG
        // 1) Info.plist GitCommitSHA injected by the build (xcodebuild passes
        //    GIT_COMMIT_SHA=$(git rev-parse HEAD); the plist value expands).
        if let sha = Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String,
           !sha.isEmpty, sha != "$(GIT_COMMIT_SHA)" {
            return String(sha.prefix(7))
        }
        // 2) -commit-sha launch argument (UI test / driver passes git rev-parse).
        if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-commit-sha"),
           ProcessInfo.processInfo.arguments.indices.contains(idx + 1) {
            return String(ProcessInfo.processInfo.arguments[idx + 1].prefix(7))
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

    // MARK: - Generic first-visible-line ancestry (any chapter, not k1-only)

    /// Walks the box tree to the first text run (lowest sourceRange.location
    /// with length > 0), then logs every ancestor box with its coordinate
    /// spaces. Generic — works for plain body pages, not just the k1 cover.
    static func logFirstVisibleLineAncestry(
        rootBox: BlockBox,
        sourceText: String,
        firstFragment: TextFragment?,
        canvasSize: CGSize,
        contentInsets: UIEdgeInsets,
        spine: Int,
        generation: Int,
        traceID: String
    ) {
        #if DEBUG
        guard let first = firstVisibleTextRun(in: rootBox) else {
            summary("\(prefix) trace=\(traceID) firstVisibleLine=none")
            return
        }
        let ns = sourceText as NSString
        let sample = ns.length > first.range.location
            ? String(ns.substring(with: NSRange(location: first.range.location, length: min(12, ns.length - first.range.location))))
            : ""
        summary("\(prefix) trace=\(traceID) firstVisibleLine sourceOffset=\(first.range.location) text=\"\(sample)\"")

        // Ancestor chain: box → parent → … → root, with accumulated offsets.
        var chain: [(box: BlockBox, docOrigin: CGPoint)] = []
        var current: BlockBox? = first.box
        var docOrigin = CGPoint.zero
        while let box = current {
            chain.append((box, docOrigin))
            if box.parentBox != nil {
                // Accumulate this box's border-box offset within the parent
                // content, plus the parent's own border+padding.
                docOrigin.x += box.frame.minX + box.borders.left + box.padding.left
                docOrigin.y += box.frame.minY + box.borders.top + box.padding.top
            }
            current = box.parentBox
        }

        let viewport = "coordinate=viewport rect=(0,0,\(String(format: "%.1f", canvasSize.width)),\(String(format: "%.1f", canvasSize.height)))"
        let content = "coordinate=viewport rect=(\(String(format: "%.1f", contentInsets.left)),\(String(format: "%.1f", contentInsets.top)),\(String(format: "%.1f", max(0, canvasSize.width - contentInsets.left - contentInsets.right))),\(String(format: "%.1f", max(0, canvasSize.height - contentInsets.top - contentInsets.bottom))))"
        summary("\(prefix) trace=\(traceID) pageViewport \(viewport)")
        summary("\(prefix) trace=\(traceID) pageContentRect \(content)")

        // Root → leaf, so the chain reads top-down.
        for (box, origin) in chain.reversed() {
            let tag = box.debugTag.isEmpty ? "(anonymous)" : box.debugTag
            let classPart = box.debugClasses.isEmpty ? "" : ".\(box.debugClasses.joined(separator: "."))"
            let idPart = box.debugID.map { "#\($0)" } ?? ""
            let parentLocal = "coordinate=parentLocal borderRect=\(rect(box.frame.rawValue, space: "parentLocal"))"
            let doc = "document borderRect=\(rect(CGRect(x: origin.x, y: origin.y, width: box.frame.width, height: box.frame.height), space: "document"))"
            let specified = "spec margin=[t:\(box.style.marginTop) r:\(box.style.marginRight) b:\(box.style.marginBottom) l:\(box.style.marginLeft)] pad=[t:\(box.style.paddingTop) r:\(box.style.paddingRight) b:\(box.style.paddingBottom) l:\(box.style.paddingLeft)]"
            let resolved = "resolved margin=[t:\(String(format: "%.2f", box.margins.top)) b:\(String(format: "%.2f", box.margins.bottom)) l:\(String(format: "%.2f", box.margins.left)) r:\(String(format: "%.2f", box.margins.right))] pad=[t:\(String(format: "%.2f", box.padding.top)) b:\(String(format: "%.2f", box.padding.bottom))]"
            summary("\(prefix) trace=\(traceID) ancestor \(tag)\(classPart)\(idPart) nodeID=\(box.debugNodeID) | \(specified) | \(resolved) | \(parentLocal) | \(doc) | accumOffset=(\(String(format: "%.2f", origin.x)),\(String(format: "%.2f", origin.y)))")
        }

        // Paragraph/line/run level.
        let run = first.run
        let style = run.style
        let line = first.line
        let box = first.box
        let lineDocY = box.documentOrigin.y + line.top
        let para = "paragraph margin=[t:\(String(format: "%.2f", box.margins.top)) b:\(String(format: "%.2f", box.margins.bottom))] pad=[t:\(String(format: "%.2f", box.padding.top)) b:\(String(format: "%.2f", box.padding.bottom))]"
        let lineInfo = "lineBox \(rect(CGRect(x: 0, y: line.top, width: 0, height: line.height), space: "boxContentLocal")) documentY=\(String(format: "%.2f", lineDocY)) baselineY=\(String(format: "%.2f", lineDocY + (line.baseline - line.top))) height=\(String(format: "%.2f", line.height))"
        let runInfo = "textRun range=\(run.sourceRange) x=\(String(format: "%.2f", run.x)) width=\(String(format: "%.2f", run.width))"
        let css = "css fontSize=\(String(format: "%.2f", style.fontSize)) lineHeight=\(style.lineHeight.map { String(format: "%.2f", $0) } ?? "nil") textAlign=\(style.textAlign.rawValue) whiteSpace=\(style.whiteSpace)"
        summary("\(prefix) trace=\(traceID) firstPara \(para) | \(lineInfo) | \(runInfo)")
        summary("\(prefix) trace=\(traceID) firstRunCss \(css)")

        if let frag = firstFragment {
            let pageLocal = "pageLocal fragmentRect=\(rect(frag.rect.rawValue, space: "pageLocal"))"
            let baseline = "baselineY=\(String(format: "%.2f", frag.baselineY))"
            let doc = "document fragmentRect=\(rect(frag.documentRect.rawValue, space: "document"))"
            var glyph = "none"
            if let line = frag.ctLine {
                let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                glyph = rect(
                    CGRect(x: frag.rect.minX + ink.minX, y: frag.baselineY - ink.maxY,
                           width: ink.width, height: ink.height),
                    space: "pageLocal"
                )
            }
            summary("\(prefix) trace=\(traceID) firstTextFragment \(pageLocal) | \(doc) | \(baseline) | glyphInk=\(glyph)")
        }
        #endif
    }

    /// Finds the first text run (smallest source offset with text) in the box
    /// tree and returns its box/line/run with the box's document origin.
    static func firstVisibleTextRun(in root: BlockBox) -> (box: BlockBox, line: LayoutLine, run: LineRun, range: NSRange)? {
        #if DEBUG
        var best: (box: BlockBox, line: LayoutLine, run: LineRun, range: NSRange)? = nil
        func walk(_ box: BlockBox) {
            for line in box.lines {
                for run in line.runs where run.atomic == nil && run.sourceRange.length > 0 {
                    if best == nil || run.sourceRange.location < best!.range.location {
                        best = (box, line, run, run.sourceRange)
                    }
                }
            }
            for child in box.children {
                walk(child)
            }
        }
        walk(root)
        if let b = best {
            var origin = CGPoint.zero
            var cursor: BlockBox? = b.box
            while let box = cursor, let parent = box.parentBox {
                origin.x += box.frame.minX + box.borders.left + box.padding.left
                origin.y += box.frame.minY + box.borders.top + box.padding.top
                cursor = parent
            }
            b.box.documentOrigin = origin
            return b
        }
        return nil
        #else
        return nil
        #endif
    }
}
