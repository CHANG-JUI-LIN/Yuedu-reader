import Foundation

/// The two offset spaces of a laid-out chapter.
///
/// `pageRanges`, attachments and drawing are in the laid-out text; reading positions,
/// annotations and everything the reader stores are in the chapter's own text. They are the
/// same space unless 整章翻譯 spliced translations in — every conversion below is the
/// identity then, so a chapter without translations behaves exactly as before.
extension CoreTextPaginator.ChapterLayout {
    /// The chapter's own text, in the offsets reading positions use.
    var sourceText: String { translation?.sourceText ?? attributedString.string }
    var sourceLength: Int { translation?.sourceLength ?? attributedString.length }

    /// Where a reading position is in the laid-out text, clamped to it.
    func displayOffset(for position: CoreTextReadingPosition) -> Int {
        let length = attributedString.length
        if position.charOffset == .max { return length }
        guard let translation else { return min(max(position.charOffset, 0), length) }
        let offset = translation.displayOffset(charOffset: position.charOffset, translationOffset: position.translationOffset)
        return min(max(offset, 0), length)
    }

    func displayOffset(forSource charOffset: Int) -> Int {
        displayOffset(for: CoreTextReadingPosition(spineIndex: spineIndex, charOffset: charOffset))
    }

    /// The reading position of a laid-out offset — inside a translation, its anchor plus how
    /// far in, so the position finds the same place again.
    func readingPosition(atDisplay offset: Int) -> CoreTextReadingPosition {
        guard let translation else { return CoreTextReadingPosition(spineIndex: spineIndex, charOffset: offset) }
        let mapped = translation.sourcePosition(displayOffset: offset)
        return CoreTextReadingPosition(spineIndex: spineIndex, charOffset: mapped.charOffset,
                                       translationOffset: mapped.translationOffset)
    }

    func sourceOffset(forDisplay offset: Int) -> Int {
        readingPosition(atDisplay: offset).charOffset
    }

    /// An annotation's place on screen; parts a translation hides are left out.
    func displayRanges(forSource range: NSRange) -> [NSRange] {
        guard let translation else { return [range] }
        return translation.displayRanges(forSource: range)
    }

    /// The book text a laid-out range covers, or nil when it takes in translation.
    func sourceRange(forDisplay range: NSRange) -> NSRange? {
        guard let translation else { return range }
        return translation.sourceRange(forDisplay: range)
    }

    func isTranslation(_ range: NSRange) -> Bool {
        translation?.isTranslation(range) ?? false
    }
}

extension CoreTextTextAnnotation {
    /// This annotation where `layout` draws it — one piece per stretch of book text between
    /// translations, all under the same id. Empty when a translation hides all of it.
    func displayed(in layout: CoreTextPaginator.ChapterLayout) -> [CoreTextTextAnnotation] {
        guard spineIndex == layout.spineIndex, layout.translation != nil else { return [self] }
        return layout.displayRanges(forSource: range).map {
            CoreTextTextAnnotation(id: id, spineIndex: spineIndex, range: $0, style: style, color: color, note: note)
        }
    }
}

extension ReaderPlaybackHighlight {
    /// The same highlight with its chapter offset hint moved into `layout`'s laid-out text.
    func displayed(in layout: CoreTextPaginator.ChapterLayout) -> ReaderPlaybackHighlight {
        guard layout.translation != nil, chapterIndex == nil || chapterIndex == layout.spineIndex,
              let offset = expectedChapterOffset else { return self }
        return withExpectedChapterOffset(layout.displayOffset(forSource: offset))
    }
}
