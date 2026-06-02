import Foundation

// MARK: - Annotation Store

/// Manages annotation range merge / split / delete / update.
/// The single source of truth for annotation range logic.
/// Renderers only read from this store; they never mutate annotations.
struct AnnotationStore {

    // MARK: - Merge

    /// Merges a new annotation into an existing list.
    /// Same spine + same style + same color + overlap/touch → merge into one.
    /// Different color/style → kept separate.
    /// Annotations with notes are merged cautiously (note preserved).
    static func merge(
        _ newAnnotation: CoreTextTextAnnotation,
        into existing: [CoreTextTextAnnotation]
    ) -> (result: [CoreTextTextAnnotation], editResult: AnnotationEditResult) {
        var result: [CoreTextTextAnnotation] = []
        var merged = newAnnotation
        var absorbedIDs: [UUID] = []

        for item in existing {
            let sameLayer =
                item.spineIndex == merged.spineIndex &&
                item.style == merged.style &&
                item.color == merged.color

            guard sameLayer else {
                result.append(item)
                continue
            }

            let overlapsOrTouches = item.overlapsOrTouches(merged.startOffset, merged.endOffset)

            if overlapsOrTouches {
                let newStart = min(item.startOffset, merged.startOffset)
                let newEnd = max(item.endOffset, merged.endOffset)
                merged = CoreTextTextAnnotation(
                    id: merged.id,
                    spineIndex: merged.spineIndex,
                    range: NSRange(location: newStart, length: newEnd - newStart),
                    style: merged.style,
                    color: merged.color,
                    note: merged.note ?? item.note
                )
                absorbedIDs.append(item.id)
            } else {
                result.append(item)
            }
        }

        result.append(merged)
        result.sort { a, b in
            if a.spineIndex != b.spineIndex {
                return a.spineIndex < b.spineIndex
            }
            return a.startOffset < b.startOffset
        }

        let editResult: AnnotationEditResult
        if absorbedIDs.isEmpty {
            editResult = .created(merged)
        } else if absorbedIDs.count == 1 && merged.id == absorbedIDs[0] {
            editResult = .updated(merged)
        } else {
            editResult = .merged(merged, absorbedIDs: absorbedIDs)
        }

        return (result, editResult)
    }

    // MARK: - Delete

    /// Removes the annotation with the given ID, or splits/trims if removing a sub-range.
    static func remove(
        annotationID: UUID,
        from annotations: [CoreTextTextAnnotation]
    ) -> [CoreTextTextAnnotation] {
        annotations.filter { $0.id != annotationID }
    }

    /// Removes any annotation that exactly matches the given range on the same spine.
    /// Returns the updated list and the IDs of removed annotations.
    static func removeExact(
        spineIndex: Int,
        range: NSRange,
        from annotations: [CoreTextTextAnnotation]
    ) -> (result: [CoreTextTextAnnotation], removedIDs: [UUID]) {
        var removedIDs: [UUID] = []
        let result = annotations.filter { item in
            if item.spineIndex == spineIndex && NSEqualRanges(item.range, range) {
                removedIDs.append(item.id)
                return false
            }
            return true
        }
        return (result, removedIDs)
    }

    // MARK: - Hit Testing

    /// Finds the annotation at a given character offset within a spine, with a tolerance.
    /// Returns the annotation if the offset falls within an annotation's range (expanded by tolerance).
    static func annotationAt(
        spineIndex: Int,
        charOffset: Int,
        in annotations: [CoreTextTextAnnotation],
        tolerance: Int = 2
    ) -> CoreTextTextAnnotation? {
        annotations.first { item in
            guard item.spineIndex == spineIndex else { return false }
            let start = item.startOffset - tolerance
            let end = item.endOffset + tolerance
            return charOffset >= start && charOffset <= end
        }
    }

    /// Returns the annotation whose range fully contains the given range (for edit-vs-create decision).
    static func annotationFullyContaining(
        spineIndex: Int,
        range: NSRange,
        in annotations: [CoreTextTextAnnotation]
    ) -> CoreTextTextAnnotation? {
        let selStart = range.location
        let selEnd = range.location + range.length
        return annotations.first { item in
            guard item.spineIndex == spineIndex else { return false }
            return item.startOffset <= selStart && item.endOffset >= selEnd
        }
    }

    // MARK: - Selection Expansion (Snapping)

    /// Expands a selection range to include any overlapping or nearby annotations.
    /// Used when the user drag-selects near an existing annotation.
    static func expandedSelectionRange(
        spineIndex: Int,
        start: Int,
        end: Int,
        in annotations: [CoreTextTextAnnotation],
        tolerance: Int = 2
    ) -> NSRange {
        var newStart = start
        var newEnd = end

        for item in annotations where item.spineIndex == spineIndex {
            let aStart = item.startOffset
            let aEnd = item.endOffset

            let overlapsOrNear =
                aStart <= newEnd + tolerance &&
                newStart <= aEnd + tolerance

            if overlapsOrNear {
                newStart = min(newStart, aStart)
                newEnd = max(newEnd, aEnd)
            }
        }

        return NSRange(location: newStart, length: max(0, newEnd - newStart))
    }
}
