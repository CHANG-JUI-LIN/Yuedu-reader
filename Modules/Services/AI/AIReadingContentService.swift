import Foundation

/// Uses the reader's existing source extraction and online chapter service. No AI cache.
@MainActor
enum AIReadingContentService {
    static func chapterRequests(_ context: AIQuestionContext) -> [Int] {
        let source = context.source
        let focus = context.selection?.spineIndex ?? source.boundary().spineIndex
        var indices = [focus]
        if context.action == .recap { indices = Array(max(0, focus - 2)...max(0, focus)) }
        let requested = AIReadingEvidence.requestedChapters(context)
        if !requested.isEmpty { indices = context.selection == nil ? requested : [focus] + requested }
        var seen = Set<Int>()
        return indices.filter { index in
            guard source.chunkSections.indices.contains(index), seen.insert(index).inserted,
                  context.boundary.wholeBook || index <= context.boundary.spineIndex else { return false }
            return source.manifest.chapters[index].status == .notDownloaded
        }
    }

    static func prepare(_ context: AIQuestionContext, book: ReadingBook?, chapters: [BookChapter],
                        renderer: EPUBPageRenderer, store: BookStore, conversion: TextConversion) async throws -> AIQuestionContext {
        guard let book, book.isOnline else { return try validateSelection(context) }
        let online = OnlineChapterContentService(book: book, store: store)
        return try await acquire(context, chapters: chapters) { index in
            _ = try await online.payload(at: index, policy: .fetchIfMissing)
            try Task.checkCancellation()
            let extracted = await renderer.localChapterText(at: index)
            guard let body = extracted.text, extracted.status == .available else {
                throw LLMError.providerError(localized("章節已取得，但無法讀取可驗證的正文。"))
            }
            return body.converted(to: conversion)
        }
    }

    /// The same bounded acquisition loop is used by the production reader and regression fixtures.
    static func acquire(_ context: AIQuestionContext, chapters: [BookChapter],
                        load: @MainActor (Int) async throws -> String) async throws -> AIQuestionContext {
        let requests = chapterRequests(context)
        guard !requests.isEmpty else { return try validateSelection(context) }
        var text: [Int: String] = [:]
        for index in requests {
            try Task.checkCancellation()
            text[index] = try await load(index)
            try Task.checkCancellation()
        }
        let old = context.source
        var updated = AIBookContentAdapter(bookID: context.bookID, chapters: chapters,
            transformationVersion: old.manifest.transformationVersion,
            missingStatus: Dictionary(uniqueKeysWithValues: old.manifest.chapters.map { ($0.order, $0.status) })) { index in
                text[index] ?? (old.chunkSections[index].text.isEmpty ? nil : old.chunkSections[index].text)
            }
        let position = old.boundary()
        updated = updated.atReadingPosition(spine: position.spineIndex, renderedOffset: position.utf16Offset,
            renderedText: old.chunkSections.indices.contains(position.spineIndex) ? old.chunkSections[position.spineIndex].text : nil)
        return try validateSelection(context.replacingSource(updated))
    }

    static func validateSelection(_ context: AIQuestionContext) throws -> AIQuestionContext {
        guard let selection = context.selection else { return context }
        guard selection.validated(in: context.source, boundary: context.boundary) else {
            throw LLMError.providerError(localized("選文已變更或超出目前閱讀範圍，請重新選取。"))
        }
        return context
    }

    static func citationOffset(_ citation: LLMCitation, source: AIBookContentAdapter,
                               boundary: AIReadingBoundary, renderer: EPUBPageRenderer) async throws -> Int {
        try await citationOffset(citation, source: source, boundary: boundary) { index in
            let text = await renderer.laidOutChapterText(at: index)
            try Task.checkCancellation()
            guard let text else {
                throw LLMError.providerError(localized("無法載入引用章節。"))
            }
            return text
        }
    }

    /// Authorize the exact source range before loading: even legacy citations must not
    /// trigger an unread chapter fetch simply because their old answer is still viewable.
    static func citationOffset(_ citation: LLMCitation, source: AIBookContentAdapter,
                               boundary: AIReadingBoundary,
                               load: @MainActor (Int) async throws -> String) async throws -> Int {
        try Task.checkCancellation()
        guard source.chunkSections.indices.contains(citation.spineIndex),
              boundary.sourceVersion == source.contentFingerprint else {
            throw LLMError.providerError(localized("來源已變更，無法驗證引用位置。"))
        }
        let text = source.chunkSections[citation.spineIndex].text
        guard let offset = AITextCoordinates.citationOffset(citation, sourceVersion: source.contentFingerprint,
                sourceText: text, renderedText: text) else {
            throw LLMError.providerError(localized("來源已變更，無法驗證引用位置。"))
        }
        guard boundary.allows(.init(spineIndex: citation.spineIndex,
                  charOffset: offset + citation.quote.utf16.count, progress: 0)) else {
            throw LLMError.providerError(localized("引用超出目前閱讀範圍。"))
        }
        let rendered = try await load(citation.spineIndex)
        try Task.checkCancellation()
        guard let renderedOffset = AITextCoordinates.citationOffset(citation, sourceVersion: source.contentFingerprint,
                sourceText: text, renderedText: rendered) else {
            throw LLMError.providerError(localized("來源已變更，無法驗證引用位置。"))
        }
        return renderedOffset
    }

}

extension AIQuestionContext {
    func replacingSource(_ source: AIBookContentAdapter) -> Self {
        let updatedBoundary = source.boundary(wholeBook: boundary.wholeBook)
        // Filling missing chapters does not change evidence already sent. Rebind only when
        // every previously available source and the transformation remain byte-identical.
        let compatible = self.source.manifest.transformationVersion == source.manifest.transformationVersion &&
            self.source.chunkSections.count == source.chunkSections.count &&
            self.source.chunkSections.enumerated().allSatisfy { i, old in
                old.id == source.chunkSections[i].id && (old.text.isEmpty || old.text.utf16.elementsEqual(source.chunkSections[i].text.utf16))
            }
        let rebased = history.map { message -> AIChatMessage in
            var value = message
            if compatible, let old = value.provenance, old.boundary.sourceVersion == self.source.contentFingerprint {
                let ceiling = AIReadingBoundary(sourceVersion: source.contentFingerprint, sectionID: old.boundary.sectionID,
                    spineIndex: old.boundary.spineIndex, utf16Offset: old.boundary.utf16Offset, wholeBook: old.boundary.wholeBook)
                value.provenance = .init(requestID: old.requestID, bookID: old.bookID, conversationID: old.conversationID,
                    boundary: ceiling, status: old.status, sentEvidence: old.sentEvidence, finalEvidenceIDs: old.finalEvidenceIDs,
                    historyMessageIDs: old.historyMessageIDs)
                value.citations = value.citations.map { citation in
                    var citation = citation
                    if citation.sourceVersion == self.source.contentFingerprint,
                       source.chunkSections.indices.contains(citation.spineIndex),
                       AITextCoordinates.citationOffset(citation, sourceVersion: self.source.contentFingerprint,
                           sourceText: self.source.chunkSections[citation.spineIndex].text,
                           renderedText: source.chunkSections[citation.spineIndex].text) != nil {
                        citation.sourceVersion = source.contentFingerprint
                    }
                    return citation
                }
            }
            return value
        }
        var value = Self(requestID: requestID, bookID: bookID, conversationID: conversationID, question: question,
            source: source, boundary: updatedBoundary, history: rebased, budget: budget)
        value.action = action; value.selection = selection; value.customPrompt = customPrompt
        value.serviceID = serviceID; value.model = model; value.provider = provider
        value.allowsBackgroundKnowledge = allowsBackgroundKnowledge
        return value
    }
}
