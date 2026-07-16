import Foundation

final class TextSelectionManager {
    private(set) var anchorIndex: Int?
    private(set) var focusIndex: Int?

    var selectedRange: NSRange? {
        guard let anchor = anchorIndex, let focus = focusIndex else { return nil }
        let start = min(anchor, focus)
        let end = max(anchor, focus)
        return NSRange(location: start, length: end - start + 1)
    }

    var hasSelection: Bool {
        guard let range = selectedRange else { return false }
        return range.length > 0
    }

    var selectionBounds: (start: Int, end: Int)? {
        guard let range = selectedRange else { return nil }
        return (range.location, range.location + range.length - 1)
    }

    func beginSelection(at index: Int, maxLength: Int) {
        let clamped = clamp(index, maxLength: maxLength)
        anchorIndex = clamped
        focusIndex = clamped
    }

    func setSelection(range: NSRange, maxLength: Int) {
        guard maxLength > 0, range.length > 0 else {
            clear()
            return
        }
        let start = clamp(range.location, maxLength: maxLength)
        let end = clamp(range.location + range.length - 1, maxLength: maxLength)
        anchorIndex = min(start, end)
        focusIndex = max(start, end)
    }

    func updateSelection(to index: Int, maxLength: Int) {
        guard anchorIndex != nil else { return }
        focusIndex = clamp(index, maxLength: maxLength)
    }

    func updateSelectionStart(to index: Int, maxLength: Int) {
        guard let bounds = selectionBounds else { return }
        let newStart = clamp(index, maxLength: maxLength)
        let end = bounds.end
        anchorIndex = min(newStart, end)
        focusIndex = max(newStart, end)
    }

    func updateSelectionEnd(to index: Int, maxLength: Int) {
        guard let bounds = selectionBounds else { return }
        let start = bounds.start
        let newEnd = clamp(index, maxLength: maxLength)
        anchorIndex = min(start, newEnd)
        focusIndex = max(start, newEnd)
    }

    func clear() {
        anchorIndex = nil
        focusIndex = nil
    }

    func selectedText(in attributedString: NSAttributedString) -> String? {
        guard let range = selectedRange,
              range.location != NSNotFound,
              range.location + range.length <= attributedString.length,
              range.length > 0
        else {
            return nil
        }
        return EPUBLanguageTypography.sourceText(in: attributedString, range: range)
    }

    private func clamp(_ index: Int, maxLength: Int) -> Int {
        guard maxLength > 0 else { return 0 }
        return min(max(0, index), maxLength - 1)
    }
}
