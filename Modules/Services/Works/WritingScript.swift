import Foundation

/// The script a text is mostly written in, coarsely: enough to tell a Chinese, Japanese or
/// Korean book from an English description of it.
enum WritingScript: Equatable {
    case cjk, latin, other

    init(of text: String) {
        var cjk = 0, latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .otherLetter where scalar.value >= 0x2E80: cjk += 1
            case .lowercaseLetter, .uppercaseLetter: if scalar.value < 0x0250 { latin += 1 }
            default: break
            }
        }
        if cjk == 0 && latin == 0 { self = .other }
        else { self = cjk >= latin ? .cjk : .latin }
    }
}
