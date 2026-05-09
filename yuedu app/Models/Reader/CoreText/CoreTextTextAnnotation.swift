import Foundation

struct CoreTextTextAnnotation: Equatable {
    let id: UUID
    let spineIndex: Int
    let range: NSRange
}

struct CoreTextUnderlineSelectionRequest {
    let position: CoreTextReadingPosition
    let length: Int
    let excerpt: String
}

extension Notification.Name {
    static let coreTextUnderlineSelectionRequested = Notification.Name("coreTextUnderlineSelectionRequested")
}

extension Bookmark {
    var coreTextTextAnnotation: CoreTextTextAnnotation? {
        guard kind == .underline, length > 0 else { return nil }
        return CoreTextTextAnnotation(
            id: id,
            spineIndex: position.spineIndex,
            range: NSRange(location: position.charOffset, length: length)
        )
    }
}
