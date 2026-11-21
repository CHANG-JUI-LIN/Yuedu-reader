import CoreText
import UIKit
import YueduCoreText

/// The second pass of a synthetic bold, for text the CoreText engine draws.
///
/// A face with no bold of its own is emboldened as WebKit does it: its glyphs are
/// drawn again, moved along the line by the offset `FontTraits.syntheticBoldAttributes`
/// puts on the run (`BrowserTextAttributes.syntheticBoldOffset`). The browser engine's
/// drawer reads that attribute; `CTLineDraw` and `CTFrameDraw` do not know it, so
/// every place this engine draws text calls here right after. Without the call a
/// Regular-only font shows no bold at all in TXT, online chapters and legacy EPUB
/// chapters, which is how it was from YueduCoreText 394c16f (2026-10-16), when the
/// attribute replaced a stroke width CoreText drew by itself.
enum SyntheticBoldPass {
    /// Draws the marked runs of `line` again. `origin` is the text position the line
    /// was just drawn at; the context's text matrix and CTM are as they were for it.
    static func draw(_ line: CTLine, at origin: CGPoint, vertical: Bool = false, in context: CGContext) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let offset = (attributes[BrowserTextAttributes.syntheticBoldOffset] as? NSNumber)?.doubleValue,
                  offset > 0 else { continue }
            // Along the line: to the right in horizontal text, down the column in
            // vertical text (CoreText's y axis points up).
            context.textPosition = vertical
                ? CGPoint(x: origin.x, y: origin.y - offset)
                : CGPoint(x: origin.x + offset, y: origin.y)
            CTRunDraw(run, context, CFRange(location: 0, length: 0))
        }
    }

    /// Draws the marked runs of every line of `frame` again, where `CTFrameDraw` put them.
    static func draw(_ frame: CTFrame, vertical: Bool = false, in context: CGContext) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
        let frameOrigin = CTFrameGetPath(frame).boundingBoxOfPath.origin
        for (index, line) in lines.enumerated() {
            draw(line, at: CGPoint(x: frameOrigin.x + origins[index].x, y: frameOrigin.y + origins[index].y),
                 vertical: vertical, in: context)
        }
    }
}
