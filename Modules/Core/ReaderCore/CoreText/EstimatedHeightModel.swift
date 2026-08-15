import CoreGraphics
import UIKit

/// Arithmetic height estimate for a run of characters — the "cheap" half of the viewport model.
///
/// `Technotes/ViewportScrollArchitecture.md` §4.1. CoreText offers no height API cheaper than
/// `CTFramesetterSuggestFrameSizeWithConstraints`, and that one line-breaks for real; stage 0
/// measured it at 43–58% of all slicing time. So the estimate has to be arithmetic:
///
///     estimatedHeight ≈ ceil(charCount / charsPerLine) × lineHeight + paragraphSpacing
///     charsPerLine    ≈ contentWidth / averageGlyphAdvance
///
/// **No `CTFramesetter*` call may ever appear in this type.** The moment one does, estimation
/// stops being cheap and the architecture loses its reason to exist.
///
/// The estimate only has to avoid being wildly wrong. Its sole job is to give the scroll bar and
/// `contentOffset` a starting value that real layout corrects as it arrives.
struct EstimatedHeightModel: Equatable {

    /// Han, Hiragana/Katakana, Hangul and full-width forms advance at essentially the full em.
    static let cjkAdvanceRatio: CGFloat = 1.0

    /// Latin lowercase averages near half an em across common text faces. This is a heuristic,
    /// not a measurement — §4.1 accepts larger error for Western text because it only shifts the
    /// scroll bar, never the rendered result.
    static let latinAdvanceRatio: CGFloat = 0.5

    /// Width available to a line of text.
    let contentWidth: CGFloat
    /// Mean horizontal advance of one character, blended across the scripts actually present.
    let averageGlyphAdvance: CGFloat
    /// Baseline-to-baseline distance, including the reader's line-height multiple and spacing.
    let lineHeight: CGFloat
    /// Added once per fragment, matching how the paragraph style spaces blocks apart.
    let paragraphSpacing: CGFloat

    init(
        contentWidth: CGFloat,
        averageGlyphAdvance: CGFloat,
        lineHeight: CGFloat,
        paragraphSpacing: CGFloat
    ) {
        self.contentWidth = max(1, contentWidth)
        self.averageGlyphAdvance = max(0.01, averageGlyphAdvance)
        self.lineHeight = max(1, lineHeight)
        self.paragraphSpacing = max(0, paragraphSpacing)
    }

    /// Derives a model from the reader's own typography.
    ///
    /// - Parameter cjkFraction: share of CJK characters in the chapter, from `ChapterOutline`'s
    ///   single scan. A CJK-heavy chapter has near-uniform advances and estimates well; a Latin
    ///   one does not, which is why the fraction is measured rather than assumed.
    static func make(
        font: UIFont,
        cjkFraction: Double,
        contentWidth: CGFloat,
        lineHeightMultiple: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> EstimatedHeightModel {
        let clampedFraction = CGFloat(min(max(cjkFraction, 0), 1))
        let ratio = cjkAdvanceRatio * clampedFraction
            + latinAdvanceRatio * (1 - clampedFraction)
        let baseLineHeight = font.lineHeight * max(lineHeightMultiple, 1) + lineSpacing
        return EstimatedHeightModel(
            contentWidth: contentWidth,
            averageGlyphAdvance: font.pointSize * ratio,
            lineHeight: baseLineHeight,
            paragraphSpacing: paragraphSpacing
        )
    }

    /// Characters that fit on one line. At least 1, so a pathologically narrow column still
    /// terminates instead of dividing by zero.
    var charactersPerLine: Int {
        max(1, Int((contentWidth / averageGlyphAdvance).rounded(.down)))
    }

    /// Estimated height of a fragment holding `characterCount` characters of text.
    ///
    /// An empty fragment still occupies one line: a blank paragraph is a real, visible gap, and
    /// returning zero would make the scroll geometry drift short on chapters with many of them.
    func estimatedHeight(characterCount: Int) -> CGFloat {
        let lines = max(1, Int(ceil(Double(max(characterCount, 0)) / Double(charactersPerLine))))
        return CGFloat(lines) * lineHeight + paragraphSpacing
    }
}
