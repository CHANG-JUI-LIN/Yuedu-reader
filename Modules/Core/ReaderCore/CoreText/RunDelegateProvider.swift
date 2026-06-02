import CoreText
import UIKit

/// Holds image layout metadata used by CTRunDelegate callbacks.
class ImageRunInfo {
    enum DisplayMode {
        case inline
        case block
    }

    let image: UIImage?
    let width: CGFloat
    let height: CGFloat
    let drawWidth: CGFloat
    let drawHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let paddingLeft: CGFloat
    let paddingRight: CGFloat
    let source: String
    let alt: String?
    let displayMode: DisplayMode
    let opacity: CGFloat

    init(
        image: UIImage?,
        width: CGFloat,
        height: CGFloat,
        drawWidth: CGFloat,
        drawHeight: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        paddingLeft: CGFloat,
        paddingRight: CGFloat,
        source: String,
        alt: String? = nil,
        displayMode: DisplayMode,
        opacity: CGFloat
    ) {
        self.image = image
        self.width = width
        self.height = height
        self.drawWidth = drawWidth
        self.drawHeight = drawHeight
        self.ascent = ascent
        self.descent = descent
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.source = source
        self.alt = alt
        self.displayMode = displayMode
        self.opacity = opacity
    }
}

/// Holds vertical inline annotation metadata. It subclasses ImageRunInfo so
/// older delegate scanners that cast all refCons to ImageRunInfo remain safe.
final class InlineAnnotationRunInfo: ImageRunInfo {
    let attributedString: NSAttributedString

    init(
        attributedString: NSAttributedString,
        advance: CGFloat,
        columnWidth: CGFloat
    ) {
        self.attributedString = attributedString
        super.init(
            image: nil,
            width: advance,
            height: advance,
            drawWidth: columnWidth,
            drawHeight: advance,
            ascent: columnWidth / 2,
            descent: columnWidth / 2,
            paddingLeft: 0,
            paddingRight: 0,
            source: "",
            displayMode: .inline,
            opacity: 1
        )
    }
}

enum RunDelegateProvider {
    static func makeImagePlaceholder(
        image: UIImage?,
        font: UIFont,
        textColor: UIColor,
        totalWidth: CGFloat,
        drawWidth: CGFloat,
        drawHeight: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        paddingLeft: CGFloat,
        paddingRight: CGFloat,
        imageSource: String,
        imageAlt: String? = nil,
        displayMode: ImageRunInfo.DisplayMode,
        opacity: CGFloat
    ) -> NSAttributedString {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).release()
            },
            getAscent: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().ascent
            },
            getDescent: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().descent
            },
            getWidth: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )

        let info = ImageRunInfo(
            image: image,
            width: totalWidth,
            height: drawHeight,
            drawWidth: drawWidth,
            drawHeight: drawHeight,
            ascent: ascent,
            descent: descent,
            paddingLeft: paddingLeft,
            paddingRight: paddingRight,
            source: imageSource,
            alt: imageAlt,
            displayMode: displayMode,
            opacity: opacity
        )

        let retained = Unmanaged.passRetained(info).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, retained) else {
            return NSAttributedString(
                string: "\u{FFFC}",
                attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                ]
            )
        }

        let string = NSMutableAttributedString(
            string: "\u{FFFC}",
            attributes: [
                .font: font,
                .foregroundColor: textColor,
            ]
        )
        string.addAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            value: delegate,
            range: NSRange(location: 0, length: string.length)
        )
        return string
    }

    static func makeInlineAnnotationPlaceholder(
        attributedString: NSAttributedString,
        placeholderFont: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        let drawingString = sanitizedInlineAnnotationString(attributedString)
        let advance = inlineAnnotationAdvance(for: drawingString)
        let columnWidth = max(1, placeholderFont.pointSize)
        CoreTextPaginator.debugVerticalLog("makeInlineAnnotationPlaceholder advance=\(advance) columnWidth=\(columnWidth) len=\(drawingString.length) text=\"\(debugPreview(drawingString.string, limit: 80))\"", verbose: true)

        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<InlineAnnotationRunInfo>.fromOpaque(pointer).release()
            },
            getAscent: { pointer in
                Unmanaged<InlineAnnotationRunInfo>.fromOpaque(pointer).takeUnretainedValue().ascent
            },
            getDescent: { pointer in
                Unmanaged<InlineAnnotationRunInfo>.fromOpaque(pointer).takeUnretainedValue().descent
            },
            getWidth: { pointer in
                Unmanaged<InlineAnnotationRunInfo>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )

        let info = InlineAnnotationRunInfo(
            attributedString: drawingString,
            advance: advance,
            columnWidth: columnWidth
        )
        let retained = Unmanaged.passRetained(info).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, retained) else {
            Unmanaged<InlineAnnotationRunInfo>.fromOpaque(retained).release()
            return attributedString
        }

        let placeholder = NSMutableAttributedString(
            string: "\u{FFFC}",
            attributes: [
                .font: placeholderFont,
                .foregroundColor: textColor,
            ]
        )
        placeholder.addAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            value: delegate,
            range: NSRange(location: 0, length: placeholder.length)
        )
        return placeholder
    }

    static func makeInlineAnnotationPlaceholders(
        attributedString: NSAttributedString,
        placeholderFont: UIFont,
        textColor: UIColor,
        maxAdvance: CGFloat
    ) -> NSAttributedString {
        let drawingString = sanitizedInlineAnnotationString(attributedString)
        let chunks = inlineAnnotationChunks(for: drawingString, maxAdvance: maxAdvance)
        guard chunks.count > 1 else {
            return makeInlineAnnotationPlaceholder(
                attributedString: drawingString,
                placeholderFont: placeholderFont,
                textColor: textColor
            )
        }

        let result = NSMutableAttributedString()
        for chunk in chunks {
            result.append(makeInlineAnnotationPlaceholder(
                attributedString: chunk,
                placeholderFont: placeholderFont,
                textColor: textColor
            ))
        }
        CoreTextPaginator.debugVerticalLog("makeInlineAnnotationPlaceholders chunks=\(chunks.count) maxAdvance=\(maxAdvance) totalLen=\(drawingString.length)")
        return result
    }

    static func sanitizedInlineAnnotationString(_ attributedString: NSAttributedString) -> NSAttributedString {
        guard attributedString.length > 0 else { return attributedString }
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let range = NSRange(location: 0, length: mutable.length)
        // These attributes are for CoreText's normal line layout. Inline annotations
        // are drawn manually in UIKit coordinates, so keeping them pushes glyphs
        // outside the small per-character draw rect and clips the note text.
        mutable.removeAttribute(.baselineOffset, range: range)
        mutable.removeAttribute(.paragraphStyle, range: range)
        return mutable
    }

    static func inlineAnnotationTextAdvance(for attributedString: NSAttributedString) -> CGFloat {
        guard attributedString.length > 0,
              let font = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        else { return 1 }
        return max(1, ceil(max(font.pointSize, font.lineHeight)))
    }

    static func makeVerticalSpacerPlaceholder(
        advance: CGFloat,
        font: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        CoreTextPaginator.debugVerticalLog("makeVerticalSpacerPlaceholder advance=\(advance) fontSize=\(font.pointSize)", verbose: true)
        return makeImagePlaceholder(
            image: nil,
            font: font,
            textColor: textColor,
            totalWidth: max(1, advance),
            drawWidth: max(1, font.pointSize),
            drawHeight: max(1, advance),
            ascent: max(1, font.pointSize) / 2,
            descent: max(1, font.pointSize) / 2,
            paddingLeft: 0,
            paddingRight: 0,
            imageSource: "",
            displayMode: .inline,
            opacity: 0
        )
    }

    private static func inlineAnnotationAdvance(for attributedString: NSAttributedString) -> CGFloat {
        let total = inlineAnnotationItemAdvances(for: attributedString).reduce(0, +)
        return max(1, ceil(total))
    }

    private static func inlineAnnotationChunks(
        for attributedString: NSAttributedString,
        maxAdvance: CGFloat
    ) -> [NSAttributedString] {
        guard attributedString.length > 0, maxAdvance > 0 else { return [attributedString] }
        let items = inlineAnnotationItems(for: attributedString)
        guard !items.isEmpty else { return [attributedString] }

        var chunks: [NSAttributedString] = []
        let current = NSMutableAttributedString()
        var currentAdvance: CGFloat = 0

        for item in items {
            let wouldOverflow = current.length > 0
                && currentAdvance > 0
                && currentAdvance + item.advance > maxAdvance
            if wouldOverflow {
                chunks.append(NSAttributedString(attributedString: current))
                current.mutableString.setString("")
                currentAdvance = 0
            }
            current.append(attributedString.attributedSubstring(from: item.range))
            currentAdvance += item.advance
        }

        if current.length > 0 {
            chunks.append(NSAttributedString(attributedString: current))
        }
        return chunks.isEmpty ? [attributedString] : chunks
    }

    private static func inlineAnnotationItemAdvances(for attributedString: NSAttributedString) -> [CGFloat] {
        inlineAnnotationItems(for: attributedString).map(\.advance)
    }

    private struct InlineAnnotationItem {
        let range: NSRange
        let advance: CGFloat
    }

    private static func inlineAnnotationItems(for attributedString: NSAttributedString) -> [InlineAnnotationItem] {
        guard attributedString.length > 0 else { return [] }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let nsString = attributedString.string as NSString
        var result: [InlineAnnotationItem] = []
        var index = 0

        while index < attributedString.length {
            var effectiveRange = NSRange(location: 0, length: 0)
            if let delegate = attributedString.attribute(delegateKey, at: index, effectiveRange: &effectiveRange) {
                let ctDelegate = delegate as! CTRunDelegate
                let ptr = CTRunDelegateGetRefCon(ctDelegate)
                let info = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
                result.append(InlineAnnotationItem(range: effectiveRange, advance: max(1, info.width)))
                index = max(index + 1, effectiveRange.location + effectiveRange.length)
                continue
            }

            let characterRange = nsString.rangeOfComposedCharacterSequence(at: index)
            let unit = attributedString.attributedSubstring(from: characterRange)
            if unit.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(InlineAnnotationItem(range: characterRange, advance: 0))
                index = characterRange.location + characterRange.length
                continue
            }
            result.append(InlineAnnotationItem(
                range: characterRange,
                advance: inlineAnnotationTextAdvance(for: unit)
            ))
            index = characterRange.location + characterRange.length
        }

        return result
    }

    private static func debugPreview(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{FFFC}", with: "OBJ")
            .replacingOccurrences(of: "\u{3000}", with: "IDEOSPACE")
        return String(normalized.prefix(limit))
    }

}
