import Foundation

struct TTSPronunciationHint: Equatable {
    let range: NSRange
    let ipa: String
}

struct TTSNarrationUnit {
    let text: String
    let pronunciationHints: [TTSPronunciationHint]

    init(text: String, pronunciationHints: [TTSPronunciationHint] = []) {
        self.text = text
        self.pronunciationHints = pronunciationHints
    }
}

struct TTSChunkRange: Equatable {
    let text: String
    let sourceRange: NSRange
}

enum TTSPronunciationProjector {
    static func project(
        _ hints: [TTSPronunciationHint],
        into chunkSourceRange: NSRange
    ) -> [TTSPronunciationHint] {
        hints.compactMap { hint in
            let intersection = NSIntersectionRange(hint.range, chunkSourceRange)
            guard intersection.length > 0 else { return nil }
            return TTSPronunciationHint(
                range: NSRange(
                    location: intersection.location - chunkSourceRange.location,
                    length: intersection.length
                ),
                ipa: hint.ipa
            )
        }
    }
}

enum TTSPronunciationAnnotator {
    static func hints(
        in attributedString: NSAttributedString,
        lexicons: [PLSLexicon],
        bookLanguage: String?
    ) -> [TTSPronunciationHint] {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        var hints: [TTSPronunciationHint] = []
        var occupiedRanges: [NSRange] = []

        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.ipaPronunciationAttribute,
            in: fullRange
        ) { value, range, _ in
            guard let ipa = value as? String, !ipa.isEmpty else { return }
            hints.append(TTSPronunciationHint(range: range, ipa: ipa))
            occupiedRanges.append(range)
        }

        let language = bookLanguage?.lowercased()
        let text = attributedString.string as NSString
        for lexicon in lexicons where lexicon.matches(language: language) {
            for lexeme in lexicon.lexemes where !lexeme.grapheme.isEmpty && !lexeme.phoneme.isEmpty {
                var searchRange = NSRange(location: 0, length: text.length)
                while searchRange.length > 0 {
                    let found = text.range(of: lexeme.grapheme, options: [], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    if !occupiedRanges.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                        hints.append(TTSPronunciationHint(range: found, ipa: lexeme.phoneme))
                        occupiedRanges.append(found)
                    }
                    let nextLocation = found.location + max(found.length, 1)
                    let end = searchRange.location + searchRange.length
                    guard nextLocation < end else { break }
                    searchRange = NSRange(location: nextLocation, length: end - nextLocation)
                }
            }
        }

        return hints.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length < $1.range.length
        }
    }
}

private extension PLSLexicon {
    func matches(language: String?) -> Bool {
        guard alphabet == nil || alphabet == "ipa" else { return false }
        guard let lexiconLanguage = self.language?.lowercased(), !lexiconLanguage.isEmpty else {
            return true
        }
        guard let language, !language.isEmpty else { return true }
        return language == lexiconLanguage
            || language.hasPrefix("\(lexiconLanguage)-")
            || lexiconLanguage.hasPrefix("\(language)-")
    }
}
