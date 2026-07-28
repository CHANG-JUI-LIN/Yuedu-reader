import CoreText
import Foundation

public enum CoreTextFramesetterFactory {
    public static func make(for attributedString: NSAttributedString) -> CTFramesetter {
        let options = [
            kCTTypesetterOptionAllowUnboundedLayout as NSAttributedString.Key: true
        ] as CFDictionary
        guard let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
            attributedString,
            options
        ) else {
            return CTFramesetterCreateWithAttributedString(attributedString)
        }
        return CTFramesetterCreateWithTypesetter(typesetter)
    }
}
