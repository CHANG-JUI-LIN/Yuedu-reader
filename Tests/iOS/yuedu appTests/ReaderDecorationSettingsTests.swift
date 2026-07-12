import Testing
import UIKit

@Suite("Reader Decoration Settings")
struct ReaderDecorationSettingsTests {
    @Test("underline and dialogue colors have independent RGB defaults")
    func independentDefaults() {
        #expect(GlobalSettings.defaultReaderUnderlineColorHex != GlobalSettings.defaultReaderDialogueHighlightColorHex)
    }

    @Test("opaque RGB values convert to UIKit colors")
    func rgbColorConversion() {
        let color = GlobalSettings.uiColor(rgbHex: 0x123456)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(red - CGFloat(0x12) / 255) < 0.001)
        #expect(abs(green - CGFloat(0x34) / 255) < 0.001)
        #expect(abs(blue - CGFloat(0x56) / 255) < 0.001)
        #expect(abs(alpha - 1) < 0.001)
    }
}
