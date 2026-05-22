import UIKit

/// Shared text selection interaction logic for both paged and scroll reading modes.
/// Owns selection state, default-range expansion, annotation snapping, and color config.
/// Each mode provides hit-testing and frame info; the interactor produces overlay-ready rects.
final class TextSelectionInteractor {

    // MARK: - State

    let selectionManager = TextSelectionManager()
    var tappedAnnotation: CoreTextTextAnnotation?
    var selectedTextForCopy: String?

    var hasSelection: Bool { selectionManager.hasSelection }
    var selectedRange: NSRange? { selectionManager.selectedRange }

    // MARK: - Color configuration (matches paged mode's yellow theme)

    var selectionFillColor: UIColor = UIColor.systemYellow.withAlphaComponent(0.30)
    var handleColor: UIColor = UIColor(red: 0.63, green: 0.40, blue: 0.00, alpha: 1.0)

    // MARK: - Annotation context

    var textAnnotations: [CoreTextTextAnnotation] = []

    // MARK: - Public API

    /// Begin selection at a character index, expanding to the paragraph/annotation range.
    func beginSelection(
        at index: Int,
        in attributedString: NSAttributedString,
        spineIndex: Int,
        maxLength: Int
    ) {
        let paragraphRange = defaultSelectionRange(around: index, in: attributedString)
        let snappedRange = AnnotationStore.expandedSelectionRange(
            spineIndex: spineIndex,
            start: paragraphRange.location,
            end: paragraphRange.location + paragraphRange.length,
            in: textAnnotations,
            tolerance: 2
        )
        tappedAnnotation = AnnotationStore.annotationFullyContaining(
            spineIndex: spineIndex,
            range: snappedRange,
            in: textAnnotations
        )
        selectionManager.setSelection(range: snappedRange, maxLength: maxLength)
        selectedTextForCopy = selectionManager.selectedText(in: attributedString)
    }

    /// Update the focus end of the selection by dragging.
    func updateSelection(to index: Int, maxLength: Int) {
        selectionManager.updateSelection(to: index, maxLength: maxLength)
    }

    /// Drag the start handle.
    func updateSelectionStart(to index: Int, maxLength: Int) {
        selectionManager.updateSelectionStart(to: index, maxLength: maxLength)
    }

    /// Drag the end handle.
    func updateSelectionEnd(to index: Int, maxLength: Int) {
        selectionManager.updateSelectionEnd(to: index, maxLength: maxLength)
    }

    /// Re-extract selected text after drag ends.
    func finalizeSelection(in attributedString: NSAttributedString) {
        selectedTextForCopy = selectionManager.selectedText(in: attributedString)
    }

    /// Re-snap selection to annotation boundaries after handle drag.
    func snapToAnnotations(spineIndex: Int, maxLength: Int) {
        guard let range = selectionManager.selectedRange else { return }
        let snapped = AnnotationStore.expandedSelectionRange(
            spineIndex: spineIndex,
            start: range.location,
            end: range.location + range.length,
            in: textAnnotations,
            tolerance: 2
        )
        selectionManager.setSelection(range: snapped, maxLength: maxLength)
    }

    /// Check if the current selection exactly matches an existing underline, for menu toggle.
    func selectedRangeHasExactUnderline(spineIndex: Int) -> Bool {
        guard let range = selectionManager.selectedRange, range.length > 0 else { return false }
        return textAnnotations.contains {
            $0.spineIndex == spineIndex && NSEqualRanges($0.range, range)
        }
    }

    func clear() {
        selectionManager.clear()
        selectedTextForCopy = nil
        tappedAnnotation = nil
    }

    // MARK: - Paragraph default selection

    /// Returns the paragraph range around the given character index, trimming leading/trailing whitespace.
    /// Falls back to a single character if the trimmed paragraph is empty.
    private func defaultSelectionRange(
        around index: Int,
        in attributedString: NSAttributedString
    ) -> NSRange {
        guard attributedString.length > 0 else { return NSRange(location: 0, length: 0) }
        let nsString = attributedString.string as NSString
        var range = nsString.paragraphRange(
            for: NSRange(location: min(max(index, 0), attributedString.length - 1), length: 0)
        )
        while range.length > 0 {
            let first = nsString.character(at: range.location)
            if CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(first)!) {
                range.location += 1
                range.length -= 1
            } else { break }
        }
        while range.length > 0 {
            let lastIdx = range.location + range.length - 1
            let last = nsString.character(at: lastIdx)
            if CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(last)!) {
                range.length -= 1
            } else { break }
        }
        if range.length > 0 { return range }
        return NSRange(location: min(max(index, 0), attributedString.length - 1), length: 1)
    }
}
