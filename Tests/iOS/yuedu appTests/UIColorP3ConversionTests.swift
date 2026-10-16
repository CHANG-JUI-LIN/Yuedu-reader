import SwiftUI
import Testing
import UIKit
@testable import yuedu_app

@Suite("Display P3 color conversion")
struct UIColorP3ConversionTests {
    @Test("Display P3 colors convert to valid hex without trapping")
    func p3ColorsStayInRange() {
        let colors: [Color] = [
            Color(.displayP3, red: 1.0, green: 0.2, blue: 0.0, opacity: 1.0),
            Color(.displayP3, red: 0.0, green: 0.9, blue: 1.0, opacity: 1.0),
            Color(.displayP3, red: 0.99, green: 0.0, blue: 0.4, opacity: 1.0),
            Color(.displayP3, red: 0.1, green: 0.05, blue: 0.9, opacity: 1.0)
        ]
        for color in colors {
            let hex = UIColor(color).rgbHex
            // Display P3 colors surface as extended-range components; the
            // conversion must clamp them instead of trapping on UInt32(negative).
            #expect(hex != nil)
            if let hex {
                #expect(hex <= 0xFFFFFF)
            }
        }
    }

    @Test("rgbHex conversion of P3 color does not crash")
    func p3ColorRgbHexDoesNotCrash() {
        let p3Color = Color(.displayP3, red: 1.0, green: 0.2, blue: 0.0, opacity: 1.0)
        let hex = UIColor(p3Color).rgbHex
        #expect(hex != nil)
    }

    /// The regex highlight editor, the dialogue bubble settings and the chapter title
    /// inspector each carried their own unclamped copy of this conversion, fed straight
    /// from ColorPicker. A Display P3 green is about -0.51 red in extended sRGB, and
    /// `UInt32(negative)` traps — the crash `8c4857f3` fixed for `UIColor.rgbHex` only.
    @Test("a SwiftUI colour converts through the one clamped path")
    func swiftUIColorHex() {
        let green = Color(.displayP3, red: 0, green: 1, blue: 0, opacity: 1)
        #expect(green.rgbHex == UIColor(green).rgbHex)
        #expect(green.rgbHex.map { $0 >> 16 } == 0)
    }
}

