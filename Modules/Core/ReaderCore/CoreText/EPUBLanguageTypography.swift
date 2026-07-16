import CoreText
import UIKit

enum EPUBHyphenationPolicy: String, Sendable {
    case unspecified
    case none
    case manual
    case auto

    init?(cssKeyword: String) {
        switch cssKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": self = .none
        case "manual": self = .manual
        case "auto": self = .auto
        case "initial": self = .unspecified
        default: return nil
        }
    }
}

enum EPUBLanguageTypography {
    static let languageAttribute = NSAttributedString.Key(kCTLanguageAttributeName as String)
    static let hyphenationPolicyAttribute = NSAttributedString.Key("ReaderEPUBHyphenationPolicy")
    static let sourceElementTagAttribute = NSAttributedString.Key("ReaderHTMLSourceElementTag")
    static let originalSoftHyphenAttribute = NSAttributedString.Key("ReaderOriginalSoftHyphen")

    static func normalizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let subtags = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = subtags.first,
              (2...8).contains(first.count),
              first.allSatisfy({ $0.isLetter }),
              subtags.dropFirst().allSatisfy({ subtag in
                  (1...8).contains(subtag.count)
                      && subtag.allSatisfy { $0.isLetter || $0.isNumber }
              })
        else { return nil }

        return subtags.enumerated().map { index, subtag in
            if index == 0 { return subtag.lowercased() }
            if subtag.count == 2, subtag.allSatisfy({ $0.isLetter }) {
                return subtag.uppercased()
            }
            return subtag.lowercased()
        }.joined(separator: "-")
    }

    static func primaryLanguage(_ raw: String?) -> String? {
        normalizedLanguage(raw)?.split(separator: "-").first.map(String.init)
    }

    static func supportsAutomaticHyphenation(_ raw: String?) -> Bool {
        guard let primary = primaryLanguage(raw) else { return false }
        return ["en", "fr", "de", "es", "it", "pt", "nl"].contains(primary)
    }

    static func sourceText(in attributedString: NSAttributedString, range: NSRange) -> String {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= attributedString.length
        else { return "" }
        let source = NSMutableAttributedString(
            attributedString: attributedString.attributedSubstring(from: range)
        )
        guard source.length > 0 else { return "" }

        let fullRange = NSRange(location: 0, length: source.length)
        var restoredIndexes: [Int] = []
        source.enumerateAttribute(originalSoftHyphenAttribute, in: fullRange) { value, markedRange, _ in
            guard value as? Bool == true else { return }
            let end = markedRange.location + markedRange.length
            for index in markedRange.location..<end
            where (source.string as NSString).character(at: index) == 0x2060 {
                restoredIndexes.append(index)
            }
        }
        for index in restoredIndexes.reversed() {
            source.mutableString.replaceCharacters(
                in: NSRange(location: index, length: 1),
                with: "\u{00AD}"
            )
        }
        return source.string
    }
}

struct EnglishLineJustificationInput {
    var text: String
    var coverage: CGFloat
    var isParagraphLastLine: Bool
    var alignment: NSTextAlignment
    var baseWritingDirection: NSWritingDirection
    var sourceElementTag: String?
    var language: String?
}

enum EnglishLineJustificationPolicy {
    static let minimumCoverage: CGFloat = 0.82

    static func shouldJustify(_ input: EnglishLineJustificationInput) -> Bool {
        guard input.alignment == .justified,
              input.baseWritingDirection == .natural || input.baseWritingDirection == .leftToRight,
              !input.isParagraphLastLine,
              input.coverage.isFinite,
              input.coverage >= minimumCoverage,
              EPUBLanguageTypography.supportsAutomaticHyphenation(input.language),
              breakableWordSpaceCount(in: input.text) >= 2,
              isLatinDominant(input.text),
              !isExcludedSourceElement(input.sourceElementTag)
        else { return false }
        return true
    }

    private static func breakableWordSpaceCount(in text: String) -> Int {
        let characters = Array(text)
        guard characters.count >= 3 else { return 0 }
        return characters.indices.dropFirst().dropLast().reduce(into: 0) { count, index in
            guard characters[index] == " ",
                  !characters[characters.index(before: index)].isWhitespace,
                  !characters[characters.index(after: index)].isWhitespace
            else { return }
            count += 1
        }
    }

    private static func isLatinDominant(_ text: String) -> Bool {
        var latin = 0
        var cjk = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A,
                 0x0061...0x007A,
                 0x00C0...0x024F:
                latin += 1
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0x3040...0x30FF,
                 0xAC00...0xD7AF:
                cjk += 1
            default:
                continue
            }
        }
        return latin > 0 && latin > cjk
    }

    private static func isExcludedSourceElement(_ rawTag: String?) -> Bool {
        guard let tag = rawTag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !tag.isEmpty
        else { return false }
        if ["pre", "code", "math", "fallback", "reader-fallback"].contains(tag) {
            return true
        }
        return tag.count == 2
            && tag.first == "h"
            && tag.last.map { ("1"..."6").contains($0) } == true
    }
}
