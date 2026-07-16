import CoreGraphics

struct MathMLAttachmentMetrics: Equatable, Sendable {
    let drawWidth: CGFloat
    let drawHeight: CGFloat
    let totalWidth: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let logicalScale: CGFloat

    static func resolve(
        naturalSize: CGSize,
        naturalAscent: CGFloat,
        naturalDescent: CGFloat,
        availableWidth: CGFloat,
        horizontalPadding: CGFloat
    ) -> MathMLAttachmentMetrics? {
        let values = [
            naturalSize.width,
            naturalSize.height,
            naturalAscent,
            naturalDescent,
            availableWidth,
            horizontalPadding,
        ]
        guard values.allSatisfy(\.isFinite),
              naturalSize.width > 0,
              naturalSize.height > 0,
              naturalAscent >= 0,
              naturalDescent >= 0,
              naturalAscent + naturalDescent > 0,
              availableWidth > 0,
              horizontalPadding >= 0
        else { return nil }

        let contentWidth = availableWidth - horizontalPadding
        guard contentWidth > 0 else { return nil }
        let scale = min(1, contentWidth / naturalSize.width)
        guard scale.isFinite, scale > 0 else { return nil }

        let drawWidth = naturalSize.width * scale
        let drawHeight = naturalSize.height * scale
        let naturalBaselineHeight = naturalAscent + naturalDescent
        let descentFraction = naturalDescent / naturalBaselineHeight
        let descent = drawHeight * descentFraction
        let ascent = drawHeight - descent

        return MathMLAttachmentMetrics(
            drawWidth: drawWidth,
            drawHeight: drawHeight,
            totalWidth: drawWidth + horizontalPadding,
            ascent: ascent,
            descent: descent,
            logicalScale: scale
        )
    }
}
