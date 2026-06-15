import UIKit

enum UserReaderFontResolver {
    static var selectedPostScriptName: String? {
        guard let postScriptName = GlobalSettings.shared.selectedReaderFontPostScript,
              !postScriptName.isEmpty
        else { return nil }
        return postScriptName
    }

    static func bodyFont(size: CGFloat, isBold: Bool = false) -> UIFont {
        let baseFont = selectedFont(size: size) ?? UIFont.systemFont(ofSize: size)
        if isBold || GlobalSettings.shared.readerFontBold {
            return boldVersion(of: baseFont, size: size)
        }
        return baseFont
    }

    static func titleFont(size: CGFloat, isBold: Bool = false) -> UIFont {
        let baseFont = selectedFont(size: size) ?? UIFont.systemFont(ofSize: size, weight: .bold)
        return boldVersion(of: baseFont, size: size)
    }

    private static func selectedFont(size: CGFloat) -> UIFont? {
        guard let postScriptName = selectedPostScriptName else { return nil }
        return UIFont(name: postScriptName, size: size)
    }

    private static func boldVersion(of font: UIFont, size: CGFloat) -> UIFont {
        if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont.systemFont(ofSize: size, weight: .bold)
    }
}
