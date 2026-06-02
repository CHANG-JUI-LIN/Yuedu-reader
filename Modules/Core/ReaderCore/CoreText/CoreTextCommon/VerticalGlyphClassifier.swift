import Foundation

enum VerticalGlyphKind {
    case cjk(String)
    case verticalPunctuation(String)
    case compressedPunctuation(String)
    case rotatedLatin(String)
    case uprightLatin(String)
}

enum VerticalGlyphClassifier {
    private static let verticalPresentationMap: [String: String] = String.staticVerticalMap

    private static let compressedSet: Set<String> = [
        "\u{FF0C}", "\u{3002}", "\u{3001}", "\u{FF0E}", ".", ",", "\u{FF61}", "\u{FF64}"
    ]

    static func classify(_ char: Character) -> VerticalGlyphKind {
        let s = String(char)

        if let presentationForm = verticalPresentationMap[s] {
            return .verticalPunctuation(presentationForm)
        }

        if compressedSet.contains(s) {
            return .compressedPunctuation(s)
        }

        if char.isASCII {
            if char.isLetter {
                return .rotatedLatin(s)
            } else {
                return .uprightLatin(s)
            }
        }

        if let scalar = char.unicodeScalars.first {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0x3040...0x309F, 0x30A0...0x30FF,
                 0xAC00...0xD7AF:
                return .cjk(s)
            default:
                break
            }
        }

        return .cjk(s)
    }
}
