import CoreText
import Foundation
import UIKit
import YueduCoreTextTypography

/// What lays one chapter out: a single `CTFramesetter` for an ordinary chapter, and up to
/// `maximumWindows` of them for a very long one.
///
/// Why a long chapter is not one typesetter. Creating a typesetter grows faster than the
/// text once the text carries the squeeze kerns `CJKTypography.applySpacing` puts on adjacent
/// punctuation (`。」`, `，「`) — every dialogue-heavy novel does. Measured 2026-11-15 on the
/// simulator, through the HTML pipeline, inside
/// `CTTypesetterCreateWithAttributedStringAndOptions` → `TCompositionEngine::AdjustSpacing`:
/// 100k / 200k / 400k / 857k characters took 292 / 529 / 5,200 / 16,613 ms on iOS 27.2 and
/// 300 / 1,787 / 14,101 ms on iOS 26.5, and a chapter builds its typesetter for the first
/// page, again for the full pagination, and again on each executor that draws it.
/// `kCTTypesetterOptionAllowUnboundedLayout` cannot go: without it Core Text drops the kerns
/// of a long string altogether.
///
/// A window is a paragraph-aligned stretch of the chapter, laid out by its own typesetter.
/// Its string is the chapter's text and attributes for that stretch, preceded by blanks of
/// the same length as the text before it, so every index a `CTFrame`, `CTLine` or `CTRun`
/// reports is still the chapter's and nothing downstream translates offsets. The lines are
/// the ones the whole-chapter typesetter makes (break offsets, widths, glyph positions and
/// run ranges compared window by window on both runtimes; pages and scroll chunks compared
/// in `CoreTextChapterFramesetterTests`). A first page needs only one window. Simulator,
/// dialogue text, one typesetter → windows, first page / full pagination / scroll slicing:
/// 400k characters 1,170 / 2,100 / 4,950 ms → 74 / 1,250 / 3,190 ms on iOS 27.2 and
/// 3,390 / 3,900 / 6,000 ms → 116 / 1,360 / 3,280 ms on iOS 26.5; 857k characters
/// 25,507 / 27,421 / 34,451 ms → 262 / 3,300 / 10,700 ms on iOS 26.5. A chapter of 60k
/// characters or fewer is laid out exactly as before.
///
/// The blanks are not free: Core Text keeps about 24 bytes for each (measured on macOS; the
/// same for a space, a newline or a zero-width character), and a page's `CTFrame` keeps its
/// window's typesetter alive. With `w` windows the blanks total `(w − 1) / 2` chapters, so
/// the count is capped: eight windows of an 857k chapter are about 70 MB of blanks.
///
/// A window holds a little more text than its share (`overlap`), because a frame that starts
/// near the end of the share fills from the paragraphs after it. When a frame or a
/// measurement reaches the end of what the window holds and the request went further, the
/// window is rebuilt longer and the request repeated, so a result never depends on where the
/// windows fall.
///
/// Like the `CTFramesetter` it replaces, one instance belongs to one executor at a time
/// (`CoreTextFramesetterCache` gives each background executor its own). The lock only keeps
/// the window table consistent; it does not make Core Text's objects shareable.
final class CoreTextChapterFramesetter: @unchecked Sendable {
    /// The shortest window; a chapter up to one and a half of these stays whole.
    static let minimumWindowLength = 64_000
    static let maximumWindows = 8
    /// Text a window holds past its share. More than a page of ordinary text, so growing a
    /// window is rare.
    static let overlap = 8_000

    let text: NSAttributedString
    private let length: Int
    /// Each window's share of the chapter, in order and without gaps. Empty when the
    /// chapter is laid out whole.
    private let shares: [NSRange]
    private let overlap: Int
    private let lock = NSLock()
    private let whole: CTFramesetter?
    private var windows: [Int: Window] = [:]

    private struct Window {
        let framesetter: CTFramesetter
        /// The end of the chapter text this window's typesetter holds.
        let end: Int
    }

    /// Test hook: windows of about this many characters, however short the chapter, each
    /// holding an eighth as much again, for the layouts made inside `withValue`. Task-local,
    /// so no other layout sees it. Nil in production.
    @TaskLocal static var windowLengthOverride: Int?

    init(_ text: NSAttributedString) {
        let windowLength = Self.windowLengthOverride
        self.text = text
        length = text.length
        let size = windowLength
            ?? max(Self.minimumWindowLength, (length + Self.maximumWindows - 1) / Self.maximumWindows)
        overlap = windowLength.map { max(1, $0 / 8) } ?? Self.overlap
        let shares = length > size + size / 2 ? Self.shares(of: text.string as NSString, size: size) : []
        if shares.count > 1 {
            self.shares = shares
            whole = nil
        } else {
            self.shares = []
            whole = CoreTextFramesetterFactory.make(for: text)
        }
    }

    /// A chapter laid out by a framesetter that already exists.
    init(_ framesetter: CTFramesetter, text: NSAttributedString) {
        self.text = text
        length = text.length
        shares = []
        overlap = Self.overlap
        whole = framesetter
    }

    var isWindowed: Bool { whole == nil }

    /// Test evidence: how many windows the chapter has, and how many have been built.
    var windowCount: Int { max(1, shares.count) }
    var builtWindowCount: Int {
        guard whole == nil else { return 1 }
        lock.lock()
        defer { lock.unlock() }
        return windows.count
    }

    // MARK: - Layout

    /// `CTFramesetterCreateFrame` over the chapter. A zero-length range runs to the
    /// chapter's end, as Core Text's does.
    func makeFrame(range: CFRange, path: CGPath, attributes: CFDictionary?) -> CTFrame {
        if let whole {
            return CTFramesetterCreateFrame(whole, range, path, attributes)
        }
        let requestedEnd = end(of: range)
        var window = window(holding: range.location)
        while true {
            let end = min(requestedEnd, window.end)
            let frame = CTFramesetterCreateFrame(
                window.framesetter, CFRange(location: range.location, length: end - range.location), path, attributes)
            guard end < requestedEnd else { return frame }
            let visible = CTFrameGetVisibleStringRange(frame)
            // The path filled before the window's text ran out: the text after it changes nothing.
            guard visible.location + visible.length >= end else { return frame }
            window = grown(window, holding: range.location)
        }
    }

    /// `CTFramesetterSuggestFrameSizeWithConstraints` over the chapter.
    func suggestFrameSize(range: CFRange, constraints: CGSize, fitRange: UnsafeMutablePointer<CFRange>?) -> CGSize {
        if let whole {
            return CTFramesetterSuggestFrameSizeWithConstraints(whole, range, nil, constraints, fitRange)
        }
        let requestedEnd = end(of: range)
        var window = window(holding: range.location)
        while true {
            let end = min(requestedEnd, window.end)
            var fit = CFRange(location: 0, length: 0)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                window.framesetter, CFRange(location: range.location, length: end - range.location), nil, constraints, &fit)
            if end == requestedEnd || fit.location + fit.length < end {
                fitRange?.pointee = fit
                return size
            }
            window = grown(window, holding: range.location)
        }
    }

    /// `CTTypesetterSuggestLineBreak` from `location`.
    func suggestLineBreak(at location: Int, width: Double) -> CFIndex {
        if let whole {
            return CTTypesetterSuggestLineBreak(CTFramesetterGetTypesetter(whole), location, width)
        }
        var window = window(holding: location)
        while true {
            let count = CTTypesetterSuggestLineBreak(CTFramesetterGetTypesetter(window.framesetter), location, width)
            guard window.end < length, location + count >= window.end else { return count }
            window = grown(window, holding: location)
        }
    }

    // MARK: - Windows

    private func end(of range: CFRange) -> Int {
        range.length == 0 ? length : min(length, range.location + range.length)
    }

    /// The window whose share holds `location`; the last one for the chapter's end.
    private func shareIndex(holding location: Int) -> Int {
        var low = 0
        var high = shares.count - 1
        while low < high {
            let middle = (low + high) / 2
            if location < NSMaxRange(shares[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    private func window(holding location: Int) -> Window {
        let index = shareIndex(holding: location)
        lock.lock()
        defer { lock.unlock() }
        if let built = windows[index] { return built }
        let share = shares[index]
        let built = build(from: share.location, to: paragraphEnd(holding: NSMaxRange(share) + overlap))
        windows[index] = built
        return built
    }

    /// The same window holding twice the text past its share that `window` did.
    private func grown(_ window: Window, holding location: Int) -> Window {
        let index = shareIndex(holding: location)
        lock.lock()
        defer { lock.unlock() }
        // Another request grew it meanwhile.
        if let built = windows[index], built.end > window.end { return built }
        let share = shares[index]
        let extra = max(overlap, window.end - NSMaxRange(share))
        let built = build(from: share.location, to: paragraphEnd(holding: window.end + extra))
        windows[index] = built
        return built
    }

    /// The end of the paragraph holding `location`, or the chapter's end.
    private func paragraphEnd(holding location: Int) -> Int {
        guard location < length else { return length }
        return NSMaxRange((text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0)))
    }

    private func build(from start: Int, to end: Int) -> Window {
        let framesetter = SourcePerfTrace.span(
            "coreText.typesetter.window", "chars=\(end - start) at=\(start) chapter=\(length)"
        ) {
            CoreTextFramesetterFactory.make(for: Self.windowText(of: text, from: start, to: end))
        }
        return Window(framesetter: framesetter, end: end)
    }

    /// `text[start..<end]` at its own indices: the text before it is replaced by blanks that
    /// end in a paragraph break, so the window's first paragraph opens as it does in the
    /// chapter. Blanks and line breaks cost the same; the chapter's own characters in one
    /// plain run cost far more (36 s for the 857k chapter's windows, against 0.6 s).
    ///
    /// The blanks carry the font of the text they stand before, and nothing else. In any
    /// other font — even one line break in the system font — every frame the window makes
    /// costs twice as much (iOS 27.2 simulator, 185 pages of a window 643k characters into
    /// the chapter: 235 ms with system-font blanks, 111 ms with the text's font, 102 ms for
    /// the same text with no blanks at all).
    static func windowText(of text: NSAttributedString, from start: Int, to end: Int) -> NSAttributedString {
        let real = text.attributedSubstring(from: NSRange(location: start, length: end - start))
        guard start > 0 else { return real }
        let blanks = String(repeating: " ", count: start - 1) + "\n"
        var attributes: [NSAttributedString.Key: Any] = [:]
        attributes[.font] = text.attribute(.font, at: start, effectiveRange: nil)
        let window = NSMutableAttributedString(string: blanks, attributes: attributes)
        window.append(real)
        return window
    }

    /// Shares of about `size` characters that end where a paragraph does. A last share
    /// shorter than half a window joins the one before it.
    static func shares(of string: NSString, size: Int) -> [NSRange] {
        var shares: [NSRange] = []
        var start = 0
        while start < string.length {
            let last = min(string.length - 1, start + size - 1)
            var end = NSMaxRange(string.paragraphRange(for: NSRange(location: last, length: 0)))
            if string.length - end < size / 2 { end = string.length }
            shares.append(NSRange(location: start, length: end - start))
            start = end
        }
        return shares
    }
}
