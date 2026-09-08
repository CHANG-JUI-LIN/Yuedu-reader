import Foundation

/// Remaps rendered UTF-16 locations through source byte ranges. Text comparisons
/// verify the mapping at a source-selected offset; they never search the book for
/// an arbitrary matching quote (which could occur in multiple chapters).
struct TXTLocationMigration {
    enum Failure: Error {
        case invalidIndex, missingSourceIdentity, unsupportedTextTransform, invalidPosition
    }

    let file: TXTMappedTextFile
    let oldIndexes: [TXTMappedChapterIndex]
    let newIndexes: [TXTMappedChapterIndex]

    init(file: TXTMappedTextFile, oldIndexes: [TXTMappedChapterIndex], newIndexes: [TXTMappedChapterIndex]) throws {
        for indexes in [oldIndexes, newIndexes] {
            var previousEnd = 0
            for (ordinal, entry) in indexes.enumerated() {
                guard entry.index == ordinal, entry.byteRange.lowerBound >= previousEnd,
                      entry.byteRange.upperBound <= file.byteCount else { throw Failure.invalidIndex }
                previousEnd = entry.byteRange.upperBound
            }
            guard !indexes.isEmpty else { throw Failure.invalidIndex }
        }
        self.file = file
        self.oldIndexes = oldIndexes
        self.newIndexes = newIndexes
    }

    func destination(for oldIndex: Int) throws -> Int {
        guard oldIndexes.indices.contains(oldIndex) else { throw Failure.invalidPosition }
        let old = oldIndexes[oldIndex]
        if let exact = newIndexes.first(where: { $0.byteRange == old.byteRange && $0.title == old.title }) {
            return exact.index
        }
        guard let containing = newIndexes.first(where: {
            $0.byteRange.lowerBound <= old.byteRange.lowerBound
                && $0.byteRange.upperBound >= old.byteRange.upperBound
                && !$0.byteRange.isEmpty
        }) else { throw Failure.missingSourceIdentity }
        return containing.index
    }

    func map(_ position: CoreTextReadingPosition, oldRendered: String, newRendered: String) throws -> CoreTextReadingPosition {
        let destination = try destination(for: position.spineIndex)
        let old = oldIndexes[position.spineIndex]
        let new = newIndexes[destination]
        let offset = position.charOffset
        guard offset >= 0, offset <= (oldRendered as NSString).length else { throw Failure.invalidPosition }
        if old.byteRange == new.byteRange, old.title == new.title {
            return .init(spineIndex: destination, charOffset: offset)
        }
        let oldBody = normalized(old.byteRange)
        let newBody = normalized(new.byteRange)
        // Rendering can introduce title markers or remove/rewrite body content.
        // Only use the source projection when the actual builder proves it.
        guard oldRendered.hasSuffix(oldBody), newRendered.hasSuffix(newBody) else {
            throw Failure.unsupportedTextTransform
        }
        let oldTitleLength = (oldRendered as NSString).length - (oldBody as NSString).length
        let newTitleLength = (newRendered as NSString).length - (newBody as NSString).length
        let prefix = normalized(new.byteRange.lowerBound..<old.byteRange.lowerBound)
        let suffix = normalized(old.byteRange.upperBound..<new.byteRange.upperBound)
        guard prefix + oldBody + suffix == newBody else { throw Failure.unsupportedTextTransform }
        let prefixLength = (prefix as NSString).length
        let mappedOffset: Int
        if offset >= oldTitleLength, !(offset == 0 && oldBody.isEmpty) {
            mappedOffset = newTitleLength + prefixLength + offset - oldTitleLength
        } else if old.title == new.title, old.byteRange.lowerBound == new.byteRange.lowerBound {
            // Only the end boundary changed; the synthesized title is unchanged.
            guard (oldRendered as NSString).substring(to: oldTitleLength)
                    == (newRendered as NSString).substring(to: newTitleLength) else {
                throw Failure.unsupportedTextTransform
            }
            mappedOffset = offset
        } else {
            // A rejected heading is now the final source line before its old body.
            let sourceTitle = old.title + "\n"
            guard prefix.hasSuffix(sourceTitle) else { throw Failure.missingSourceIdentity }
            let titleStart = newTitleLength + prefixLength - (sourceTitle as NSString).length
            let renderedPrefix = (oldRendered as NSString).substring(to: oldTitleLength) as NSString
            let titleRange = renderedPrefix.range(of: old.title)
            if offset == 0 {
                mappedOffset = titleStart
            } else {
                guard titleRange.location != NSNotFound,
                      offset >= titleRange.location, offset <= NSMaxRange(titleRange) else {
                    throw Failure.unsupportedTextTransform
                }
                mappedOffset = titleStart + offset - titleRange.location
            }
        }
        guard mappedOffset >= 0, mappedOffset <= (newRendered as NSString).length else {
            throw Failure.invalidPosition
        }
        return .init(spineIndex: destination, charOffset: mappedOffset)
    }

    private func normalized(_ range: Range<Int>) -> String {
        TXTChapterParser.paragraphsForChapterContent(file.string(in: range))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }.joined()
    }
}
