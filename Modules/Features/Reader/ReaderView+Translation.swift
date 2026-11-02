import SwiftUI

/// 整章翻譯 in the reader: what to translate, and laying chapters out again as their
/// translations arrive.
extension ReaderView {
    /// What the reader lays out: the book's 整章翻譯 setting, or nothing without Pro. The
    /// setting itself is kept for when Pro returns (`ReaderPremiumVisibilityPolicy.allowsAI`).
    var effectiveReaderTranslation: ReaderTranslationPresentation {
        readerPremiumVisibility.allowsAI ? readerTranslation : .off
    }

    /// The chapter on screen and where in it the reader is, in the chapter's own text.
    var translationReadingPosition: (spineIndex: Int, charOffset: Int)? {
        guard let engine = epubRenderer.engine else { return nil }
        return displayedCoreTextPosition(in: engine)
    }

    /// A chapter's own text once it is laid out — the text the translations are cut from.
    func translationSourceText(forSpine spine: Int) -> String? {
        let text = effectiveScrollMode
            ? epubRenderer.scrollEngine?.chapterText(forSpine: spine)
            : epubRenderer.engine?.chapterText(forSpine: spine)
        return text?.isEmpty == false ? text : nil
    }

    /// Asks for whatever the chapter on screen is still missing. Called wherever the
    /// reader may have reached such a chapter; cheap when there is nothing to do. A failed
    /// run is left for the reader to retry from the sheet rather than retried on every turn.
    func translateVisibleChapterIfNeeded() {
        guard effectiveReaderTranslation.isActive, let position = translationReadingPosition else { return }
        translateChapter(position.spineIndex, readingOffset: position.charOffset, force: false)
    }

    func translateChapter(_ spine: Int, readingOffset: Int, force: Bool) {
        let service = AIChapterTranslationService.shared
        let chapter = AIChapterTranslationService.Chapter(book: bookId, spine: spine, language: readerTranslation.language)
        if !force, service.runs[chapter] != nil { return }
        guard let text = translationSourceText(forSpine: spine) else { return }
        service.translate(chapter, text: text, readingOffset: readingOffset, bookTitle: book?.title)
    }

    /// A batch of a chapter's translations landed: lay the chapter out again with them. Once
    /// the chapter on screen is done, the next one is translated ahead of the reader.
    func applyTranslationUpdate(_ chapter: AIChapterTranslationService.Chapter) {
        guard chapter.book == bookId, effectiveReaderTranslation.isActive, chapter.language == readerTranslation.language else { return }
        if effectiveScrollMode {
            if chapter.spine == translationReadingPosition?.spineIndex {
                let request = chapterContentRefreshRequest(chapterIndex: chapter.spine)
                let renderer = epubRenderer
                Task { @MainActor in _ = await renderer.refresh(request) }
            } else {
                // Scroll mode keeps neighbouring chapters sliced; this one picks up its
                // translations when it becomes the chapter on screen.
                epubRenderer.scrollEngine?.invalidateChapterDocument(at: chapter.spine)
                staleTranslatedChapters.insert(chapter.spine)
            }
        } else {
            submitChapterContentRefresh(chapterIndex: chapter.spine, update: .replaced)
        }
        if AIChapterTranslationService.shared.runs[chapter] == .finished,
           chapter.spine == translationReadingPosition?.spineIndex,
           chapter.spine + 1 < spineChapters.count {
            translateChapter(chapter.spine + 1, readingOffset: 0, force: false)
        }
    }

    /// The reader reached another chapter: in scroll mode, bring in translations that
    /// arrived while it was off screen, then ask for what it still lacks.
    func translationChapterDidChange() {
        guard effectiveReaderTranslation.isActive else { return }
        if effectiveScrollMode, let spine = translationReadingPosition?.spineIndex, staleTranslatedChapters.remove(spine) != nil {
            let request = chapterContentRefreshRequest(chapterIndex: spine)
            let renderer = epubRenderer
            Task { @MainActor in _ = await renderer.refresh(request) }
        }
        translateVisibleChapterIfNeeded()
    }

    /// Pro started or lapsed. The layout follows by itself (`effectiveReaderTranslation` is
    /// part of the render settings); runs have to be stopped or asked for.
    func aiAccessDidChange() {
        if readerPremiumVisibility.allowsAI {
            translateVisibleChapterIfNeeded()
        } else {
            AIChapterTranslationService.shared.cancel(book: bookId)
        }
    }

    /// The book's setting changed in the sheet: keep it, and stop paying for a language or
    /// a mode the reader has left.
    func readerTranslationDidChange(from old: ReaderTranslationPresentation, to new: ReaderTranslationPresentation) {
        ReaderTranslationSettingsStore.setPresentation(new, for: bookId)
        if !new.isActive || old.language != new.language {
            AIChapterTranslationService.shared.cancel(book: bookId)
        }
        staleTranslatedChapters.removeAll()
        translateVisibleChapterIfNeeded()
    }
}
