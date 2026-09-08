import CoreText
import Foundation
import UIKit

struct RubyLinePiece {
    let text: String
    let style: ComputedStyle
    let sourceRange: NSRange
    let shapedRange: NSRange
    let nodeID: Int
    let linkTarget: String?
    let font: UIFont
    let x: CGFloat
    let width: CGFloat
}

struct RubyLine {
    let line: CTLine
    let pieces: [RubyLinePiece]
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
}

/// The measured outer inline box. Its single advance is atomic to the parent
/// line breaker, while base and annotation retain independent shaped lines.
struct RubyBox {
    let unit: RubyInlineUnit
    let advance: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let base: RubyLine
    let annotation: RubyLine
    let baseOffsetX: CGFloat
    let annotationOffsetX: CGFloat
    let annotationBaselineOffset: CGFloat
}

enum RubyInlineLayout {
    private struct InputPiece {
        let text: String
        let style: ComputedStyle
        let sourceRange: NSRange
        let nodeID: Int
        let linkTarget: String?
    }

    static func measure(
        unit: RubyInlineUnit,
        fontResolver: (([String], Int, Bool, CGFloat) -> UIFont?)?,
        attributedSource: NSAttributedString? = nil
    ) -> RubyBox {
        let base = shape(
            unit.base.map {
                InputPiece(
                    text: $0.text,
                    style: $0.style,
                    sourceRange: $0.sourceRange,
                    nodeID: $0.nodeID,
                    linkTarget: $0.linkTarget
                )
            },
            fontResolver: fontResolver,
            attributedSource: attributedSource
        )
        let annotation = shape(
            unit.annotation.pieces.map {
                InputPiece(
                    text: $0.text,
                    style: $0.style,
                    sourceRange: unit.sourceRange,
                    nodeID: $0.nodeID,
                    linkTarget: $0.linkTarget ?? unit.linkTarget
                )
            },
            fontResolver: fontResolver
        )
        let advance = max(base.width, annotation.width)
        return RubyBox(
            unit: unit,
            advance: advance,
            ascent: base.ascent + annotation.ascent + annotation.descent,
            descent: base.descent,
            base: base,
            annotation: annotation,
            baseOffsetX: (advance - base.width) / 2,
            annotationOffsetX: (advance - annotation.width) / 2,
            annotationBaselineOffset: -base.ascent - annotation.descent
        )
    }

    private static func shape(
        _ inputs: [InputPiece],
        fontResolver: (([String], Int, Bool, CGFloat) -> UIFont?)?,
        attributedSource: NSAttributedString? = nil
    ) -> RubyLine {
        let attributed = NSMutableAttributedString()
        var starts: [Int] = []
        var fonts: [UIFont] = []
        for input in inputs {
            starts.append(attributed.length)
            let font = InlineLayout.resolvedFont(for: input.style, resolver: fontResolver)
            fonts.append(font)
            if let attributedSource {
                attributed.append(attributedSource.attributedSubstring(from: input.sourceRange))
            } else {
                attributed.append(NSAttributedString(
                    string: input.text,
                    attributes: InlineLayout.textAttributes(for: input.style, resolver: fontResolver)
                ))
            }
        }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let measured = inputs.indices.map { index -> RubyLinePiece in
            let start = starts[index]
            let end = start + (inputs[index].text as NSString).length
            let x0 = CTLineGetOffsetForStringIndex(line, start, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, end, nil)
            return RubyLinePiece(
                text: inputs[index].text,
                style: inputs[index].style,
                sourceRange: inputs[index].sourceRange,
                shapedRange: NSRange(location: start, length: end - start),
                nodeID: inputs[index].nodeID,
                linkTarget: inputs[index].linkTarget,
                font: fonts[index],
                x: x0,
                width: max(0, x1 - x0)
            )
        }
        return RubyLine(
            line: line,
            pieces: measured,
            width: width,
            ascent: ascent,
            descent: descent
        )
    }
}

/// Retained by the outer placeholder's CTRunDelegate for as long as CoreText
/// retains the shaped parent line.
final class RubyRunDelegateBox {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(_ ruby: RubyBox) {
        width = ruby.advance
        ascent = ruby.ascent
        descent = ruby.descent
    }

    static let callbacks: CTRunDelegateCallbacks = {
        CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { pointer in
                _ = Unmanaged<RubyRunDelegateBox>.fromOpaque(pointer).takeRetainedValue()
            },
            getAscent: { pointer in
                Unmanaged<RubyRunDelegateBox>.fromOpaque(pointer).takeUnretainedValue().ascent
            },
            getDescent: { pointer in
                Unmanaged<RubyRunDelegateBox>.fromOpaque(pointer).takeUnretainedValue().descent
            },
            getWidth: { pointer in
                Unmanaged<RubyRunDelegateBox>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )
    }()
}
