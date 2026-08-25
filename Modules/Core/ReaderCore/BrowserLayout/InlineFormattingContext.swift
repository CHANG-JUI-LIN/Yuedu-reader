import CoreGraphics
import Foundation
import UIKit

/// Used first-line constraints after BlockLayout resolves authored values.
/// The full positive indent is preserved even when it exhausts the interval;
/// InlineLayout then emits one overflowing atomic/grapheme unit to progress.
struct InlineFirstLineConstraint: Equatable {
    let textIndent: CGFloat

    static let none = InlineFirstLineConstraint(textIndent: 0)

    var isActive: Bool { textIndent > 0 }

    func apply(to interval: InlineInterval) -> InlineInterval {
        guard isActive else { return interval }
        return InlineInterval(
            lineX: interval.lineX + textIndent,
            lineWidth: max(0, interval.lineWidth - textIndent),
            leftIntrusion: interval.leftIntrusion,
            rightIntrusion: interval.rightIntrusion
        )
    }
}

/// Immutable inputs for one inline formatting context. The containing inline
/// size is resolved by the block-formatting owner before InlineLayout shapes or
/// breaks any content. Phase 4E0 intentionally has no first-line modifier;
/// text-indent is introduced only after geometry parity is proven.
struct InlineFormattingContext {
    let containingInlineSize: CGFloat
    let rootFontSize: CGFloat
    let lineHeight: CGFloat?
    let writingMode: ReaderWritingMode
    let sourceText: String
    let fontResolver: (([String], Int, Bool, CGFloat) -> UIFont?)?
    let floatContext: FloatContext?
    let blockOffsetY: CGFloat
    let firstLineConstraint: InlineFirstLineConstraint

    init(
        containingInlineSize: CGFloat,
        rootFontSize: CGFloat,
        lineHeight: CGFloat?,
        writingMode: ReaderWritingMode,
        sourceText: String,
        fontResolver: (([String], Int, Bool, CGFloat) -> UIFont?)?,
        floatContext: FloatContext?,
        blockOffsetY: CGFloat,
        firstLineConstraint: InlineFirstLineConstraint = .none
    ) {
        self.containingInlineSize = containingInlineSize
        self.rootFontSize = rootFontSize
        self.lineHeight = lineHeight
        self.writingMode = writingMode
        self.sourceText = sourceText
        self.fontResolver = fontResolver
        self.floatContext = floatContext
        self.blockOffsetY = blockOffsetY
        self.firstLineConstraint = firstLineConstraint
    }

    var baseInterval: InlineInterval {
        InlineInterval(
            lineX: 0,
            lineWidth: containingInlineSize,
            leftIntrusion: 0,
            rightIntrusion: 0
        )
    }

    func baseAvailableInterval(y: CGFloat, height: CGFloat) -> InlineInterval {
        floatContext?.availableInterval(y: y, height: height) ?? baseInterval
    }

    func availableInterval(
        y: CGFloat,
        height: CGFloat,
        isFirstLine: Bool
    ) -> InlineInterval {
        let interval = baseAvailableInterval(y: y, height: height)
        return isFirstLine ? firstLineConstraint.apply(to: interval) : interval
    }
}
