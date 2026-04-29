import UIKit

enum UserReaderFontResolver {
    static var selectedPostScriptName: String? {
        guard let postScriptName = GlobalSettings.shared.selectedReaderFontPostScript,
              !postScriptName.isEmpty
        else { return nil }
        return postScriptName
    }

    static func bodyFont(size: CGFloat) -> UIFont {
        selectedFont(size: size) ?? UIFont.systemFont(ofSize: size)
    }

    static func titleFont(size: CGFloat) -> UIFont {
        guard let font = selectedFont(size: size) else {
            return UIFont.systemFont(ofSize: size, weight: .bold)
        }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func selectedFont(size: CGFloat) -> UIFont? {
        guard let postScriptName = selectedPostScriptName else { return nil }
        return UIFont(name: postScriptName, size: size)
    }
}
