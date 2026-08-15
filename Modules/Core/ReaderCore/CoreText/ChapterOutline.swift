import CoreGraphics
import CoreText
import Foundation
import UIKit

/// The cheap, enumerable description of a chapter: where its paragraphs start and end, and
/// roughly how tall each one will be — derived without laying out a single line.
///
/// `Technotes/ViewportScrollArchitecture.md` §4. This is the layer the current engine lacks: today
/// `CoreTextChunkSlicer.slice()` is the only thing that knows a chapter's shape, and it learns it
/// by laying the whole chapter out.
///
/// **Nothing here may call `CTFramesetter*`.** The scan reads newlines and run-delegate
/// attachments, both of which are already in the attributed string.
struct ChapterOutline: Equatable {

    let chapterIndex: Int
    private(set) var fragments: [FragmentDescriptor]
    /// Share of CJK characters, measured during the same scan that finds the boundaries. Feeds
    /// `EstimatedHeightModel`, whose accuracy depends on it.
    let cjkFraction: Double

    var totalEstimatedHeight: CGFloat {
        fragments.reduce(0) { $0 + $1.height }
    }

    /// Whether any fragment is still carrying an estimate rather than a measured height.
    var hasEstimates: Bool {
        fragments.contains(where: \.isEstimate)
    }

    // MARK: - Building

    /// Splits `attributedString` at paragraph boundaries and estimates each fragment's height.
    ///
    /// Two passes over the string, both linear and neither touching CoreText layout: one to
    /// measure the CJK fraction (which the height model needs before it can estimate anything),
    /// then one to cut fragments and size them.
    static func make(
        attributedString: NSAttributedString,
        chapterIndex: Int,
        font: UIFont,
        contentWidth: CGFloat,
        lineHeightMultiple: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> ChapterOutline {
        let text = attributedString.string as NSString
        let cjkFraction = Self.cjkFraction(in: text)
        let model = EstimatedHeightModel.make(
            font: font,
            cjkFraction: cjkFraction,
            contentWidth: contentWidth,
            lineHeightMultiple: lineHeightMultiple,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing
        )
        return ChapterOutline(
            chapterIndex: chapterIndex,
            fragments: fragments(in: attributedString, text: text, model: model),
            cjkFraction: cjkFraction
        )
    }

    /// Builds an outline from chunks that have already been laid out.
    ///
    /// Stage 1 of the migration (§7): the chunk list is still what the collection view scrolls,
    /// so the geometry store has to report exactly the heights those chunks already have. Every
    /// descriptor therefore lands in `.laidOut` carrying its measured extent — **no estimate can
    /// reach the screen at this stage**, which is what makes "heights identical to before" true
    /// by construction rather than by luck.
    ///
    /// Stage 3 replaces this with `make(attributedString:…)` driving layout instead of trailing it.
    static func measured(
        chapterIndex: Int,
        chunks: ArraySlice<CoreTextChunk>,
        extent: (CoreTextChunk) -> CGFloat
    ) -> ChapterOutline {
        let fragments = chunks.map { chunk -> FragmentDescriptor in
            let height = extent(chunk)
            var descriptor = FragmentDescriptor(
                charRange: chunk.charRange,
                estimatedHeight: height
            )
            descriptor.recordActualHeight(height, laidOut: true)
            return descriptor
        }
        return ChapterOutline(chapterIndex: chapterIndex, fragments: fragments, cjkFraction: 0)
    }

    /// Splits a flat chunk list into one outline per chapter, in scroll order.
    ///
    /// Grouping comes from each chunk's own `chapterIndex` — deliberately **not** from a separate
    /// chapter→range map. Deriving it from a second, independently updated structure means the
    /// two can be read out of step, and any chunk the map fails to cover silently drops off the
    /// flat index and reports zero extent. Reading one source makes the mapping total by
    /// construction: every chunk lands in exactly one outline, and flat index `i` is `chunks[i]`.
    static func grouped(
        chunks: [CoreTextChunk],
        extent: (CoreTextChunk) -> CGFloat
    ) -> [ChapterOutline] {
        var result: [ChapterOutline] = []
        var index = 0
        // A chapter's chunks are contiguous, so a single pass over runs is enough.
        while index < chunks.count {
            let chapter = chunks[index].chapterIndex
            var end = index
            while end < chunks.count, chunks[end].chapterIndex == chapter {
                end += 1
            }
            result.append(measured(chapterIndex: chapter, chunks: chunks[index..<end], extent: extent))
            index = end
        }
        return result
    }

    /// Paragraph ranges, each sized by the model — except where an attachment gives an exact
    /// height, which is preferred because it is already known rather than guessed (§4.1).
    private static func fragments(
        in attributedString: NSAttributedString,
        text: NSString,
        model: EstimatedHeightModel
    ) -> [FragmentDescriptor] {
        let length = text.length
        guard length > 0 else { return [] }

        var result: [FragmentDescriptor] = []
        var start = 0
        while start < length {
            // The newline belongs to the fragment it terminates: CoreText lays it out as part of
            // that paragraph, so excluding it would make the descriptor's range disagree with the
            // chunk's — the boundary-authority failure in §8.2.
            let searchRange = NSRange(location: start, length: length - start)
            let newline = text.range(of: "\n", options: [], range: searchRange)
            let end = newline.location == NSNotFound ? length : newline.location + newline.length
            let range = CFRange(location: start, length: end - start)

            let intrinsic = attachmentHeight(in: attributedString, range: range)
            let textLength = intrinsic == nil ? range.length : 0
            result.append(
                FragmentDescriptor(
                    charRange: range,
                    estimatedHeight: intrinsic ?? model.estimatedHeight(characterCount: textLength),
                    intrinsicHeight: intrinsic
                )
            )
            start = end
        }
        return result
    }

    /// Tallest block attachment in `range`, or `nil` when the fragment is ordinary text.
    ///
    /// Reads the same `kCTRunDelegateAttributeName` / `ImageRunInfo` pairing that
    /// `CoreTextChunkSlicer.blockImageHeight` uses, so both agree on what an image is worth.
    /// Spacer runs are skipped for the same reason they are there: they carry no drawn content.
    private static func attachmentHeight(
        in attributedString: NSAttributedString,
        range: CFRange
    ) -> CGFloat? {
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location >= 0,
              nsRange.location + nsRange.length <= attributedString.length
        else { return nil }

        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var maxHeight: CGFloat = 0
        attributedString.enumerateAttribute(delegateKey, in: nsRange, options: []) { value, effectiveRange, _ in
            guard let value else { return }
            guard attributedString.attribute(
                HTMLAttributedStringBuilder.spacerRunAttribute,
                at: effectiveRange.location,
                effectiveRange: nil
            ) == nil else { return }
            let delegate = value as! CTRunDelegate
            let pointer = CTRunDelegateGetRefCon(delegate)
            let info = Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue()
            if info.displayMode == .block {
                maxHeight = max(maxHeight, info.drawHeight)
            }
        }
        return maxHeight > 0 ? maxHeight : nil
    }

    /// Fraction of CJK characters, sampled rather than counted in full.
    ///
    /// Stride sampling keeps this O(1)-ish on a long chapter: the value only steers an estimate,
    /// and a chapter's script mix is uniform enough that every 16th character settles it.
    static func cjkFraction(in text: NSString) -> Double {
        let length = text.length
        guard length > 0 else { return 0 }
        let stride = max(1, length / 512)

        var sampled = 0
        var cjk = 0
        var index = 0
        while index < length {
            let unit = text.character(at: index)
            // Skip the low surrogate half of a pair; the scalars it forms (rare CJK Ext-B and
            // emoji) are not worth decoding for an estimate.
            if !(unit >= 0xDC00 && unit <= 0xDFFF) {
                sampled += 1
                if isCJK(unit) { cjk += 1 }
            }
            index += stride
        }
        guard sampled > 0 else { return 0 }
        return Double(cjk) / Double(sampled)
    }

    /// Full-width scripts, i.e. those advancing at roughly one em.
    private static func isCJK(_ unit: unichar) -> Bool {
        switch unit {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFF60,   // Full-width forms
             0xFFE0...0xFFE6:   // Full-width signs
            return true
        default:
            return false
        }
    }

    // MARK: - Mutation

    /// Records a measured height for the fragment at `index`.
    mutating func recordActualHeight(_ height: CGFloat, at index: Int, laidOut: Bool) {
        guard fragments.indices.contains(index) else { return }
        fragments[index].recordActualHeight(height, laidOut: laidOut)
    }

    /// Index of the fragment containing `location`, or `nil` when it falls outside the chapter.
    ///
    /// Binary search: this runs per scroll event once the viewport controller is driving layout.
    func fragmentIndex(containing location: CFIndex) -> Int? {
        var low = 0
        var high = fragments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = fragments[mid].charRange
            if location < range.location {
                high = mid - 1
            } else if location >= range.location + range.length {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }
}
