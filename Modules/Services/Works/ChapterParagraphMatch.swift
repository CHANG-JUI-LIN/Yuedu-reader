import Foundation

/// Which paragraph of the chapter being read a site's 段評 or 熱評 is about (design
/// `Technotes/ChapterCommentsModule-2026-11-15-design.md` §4.2). The reader's copy and the
/// site's are two editions, cut into paragraphs each its own way, so a paragraph is told by its
/// text; by its number only when the site says how many paragraphs its chapter has and the
/// reader's has as many. One that cannot be told gets nothing: a comment under another
/// paragraph is worse than none.
enum ChapterParagraphMatch {
    /// Text as paragraphs are compared: a title's fold (`WorkMatchKey`), so the script, the
    /// width, the indentation and the punctuation of an edition do not count.
    static func fold(_ text: String) -> String { WorkMatchKey.title(text) }

    /// A quote this short is in too many paragraphs to tell one (「嗯。」).
    static let minimumQuoteLength = 4

    /// The chapter's own paragraphs, folded, with where each is in `paragraphs` (the chapter's
    /// paragraphs' text, in order): without the chapter's title, which stands before the text.
    static func body(of paragraphs: [String], title: String) -> [(position: Int, key: String)] {
        let titleKey = fold(title)
        var body: [(position: Int, key: String)] = []
        for (position, paragraph) in paragraphs.enumerated() {
            let key = fold(paragraph)
            guard !key.isEmpty else { continue }
            // The title block: the first lines, each all of it or a part of it (number and name
            // on two lines).
            if body.isEmpty, !titleKey.isEmpty, titleKey.contains(key) { continue }
            body.append((position, key))
        }
        return body
    }

    /// Where `reference`'s paragraph is in `body` (an index into it), nil when it cannot be told.
    ///
    /// - By its `quote`: the one paragraph that is it, or begins with it. None, or several
    ///   (a line a character says twice), is no match.
    /// - Without a quote, by its `index`, when `remoteCount` is `body`'s own count.
    static func index(of reference: ModuleParagraphReference, in body: [String], remoteCount: Int?) -> Int? {
        if !reference.quote.isEmpty {
            guard reference.quote.count >= minimumQuoteLength else { return nil }
            var found: Int?
            for (index, key) in body.enumerated() where key.hasPrefix(reference.quote) {
                if found != nil { return nil }
                found = index
            }
            return found
        }
        guard let number = reference.index, let remoteCount, remoteCount == body.count, body.indices.contains(number - 1) else {
            return nil
        }
        return number - 1
    }
}
