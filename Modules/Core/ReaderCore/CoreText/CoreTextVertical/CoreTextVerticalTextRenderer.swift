import UIKit
import CoreText

/// Vertical writing mode (vertical-rl) text rendering.
///
/// CoreText handles glyph rotation and right-to-left column progression
/// automatically when kCTFrameProgressionAttributeName = .rightToLeft
/// and kCTVerticalFormsAttributeName = true are set.
/// We simply call CTFrameDraw — CoreText does the rest.
///
/// Interaction geometry for vertical pages lives in CoreTextPageView; this
/// renderer only draws the CTFrame.
enum CoreTextVerticalTextRenderer {

    /// Draw a CTFrame configured for vertical-rl text.
    /// Caller must have already applied the CoreText → UIKit coordinate flip.
    static func draw(_ frame: CTFrame, in ctx: CGContext) {
        CTFrameDraw(frame, ctx)
    }
}
