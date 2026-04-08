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

    func beginSelection(at index: Int, maxLength: Int) {
        let clamped = clamp(index, maxLength: maxLength)
        anchorIndex = clamped
        focusIndex = clamped
    }

    func updateSelection(to index: Int, maxLength: Int) {
        guard anchorIndex != nil else { return }
        focusIndex = clamp(index, maxLength: maxLength)
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
        return (attributedString.string as NSString).substring(with: range)
    }

    private func clamp(_ index: Int, maxLength: Int) -> Int {
        guard maxLength > 0 else { return 0 }
        return min(max(0, index), maxLength - 1)
    }
}
