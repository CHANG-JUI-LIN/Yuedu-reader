import Foundation

// MARK: - Annotation Style & Color

enum AnnotationStyle: String, Codable, CaseIterable {
    case highlight
    case underline
}

enum AnnotationColor: String, Codable, CaseIterable {
    case yellow
    case green
    case blue
    case pink
    case orange
}

#if canImport(UIKit)
import UIKit

extension AnnotationColor {
    var uiColor: UIColor {
        switch self {
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .pink: return .systemPink
        case .orange: return .systemOrange
        }
    }
}
#endif

// MARK: - Text Annotation

struct CoreTextTextAnnotation: Equatable {
    let id: UUID
    let spineIndex: Int
    let range: NSRange
    var style: AnnotationStyle
    var color: AnnotationColor
    var note: String?

    var startOffset: Int { range.location }
    var endOffset: Int { range.location + range.length }

    init(
        id: UUID = UUID(),
        spineIndex: Int,
        range: NSRange,
        style: AnnotationStyle = .underline,
        color: AnnotationColor = .yellow,
        note: String? = nil
    ) {
        self.id = id
        self.spineIndex = spineIndex
        self.range = range
        self.style = style
        self.color = color
        self.note = note
    }

    /// Whether this annotation overlaps or touches another range on the same spine.
    func overlapsOrTouches(_ otherStart: Int, _ otherEnd: Int) -> Bool {
        let aStart = startOffset
        let aEnd = endOffset
        return aStart <= otherEnd && otherStart <= aEnd
    }
}

// MARK: - Underline Selection Request

struct CoreTextUnderlineSelectionRequest {
    let position: CoreTextReadingPosition
    let length: Int
    let excerpt: String
    let removesExistingUnderline: Bool
    let style: AnnotationStyle
    let color: AnnotationColor

    init(
        position: CoreTextReadingPosition,
        length: Int,
        excerpt: String,
        removesExistingUnderline: Bool = false,
        style: AnnotationStyle = .underline,
        color: AnnotationColor = .yellow
    ) {
        self.position = position
        self.length = length
        self.excerpt = excerpt
        self.removesExistingUnderline = removesExistingUnderline
        self.style = style
        self.color = color
    }
}

extension Notification.Name {
    static let coreTextUnderlineSelectionRequested = Notification.Name("coreTextUnderlineSelectionRequested")
}

// MARK: - Annotation Edit Result

enum AnnotationEditResult {
    case created(CoreTextTextAnnotation)
    case merged(CoreTextTextAnnotation, absorbedIDs: [UUID])
    case updated(CoreTextTextAnnotation)
}

// MARK: - Layer Key

/// Identifies an annotation rendering layer by (style, color) for multi-layer overlay management.
struct LayerKey: Hashable {
    let style: AnnotationStyle
    let color: AnnotationColor
}

// MARK: - Bookmark Bridge

extension Bookmark {
    var coreTextTextAnnotation: CoreTextTextAnnotation? {
        guard (kind == .underline || kind == .highlight), length > 0 else { return nil }
        return CoreTextTextAnnotation(
            id: id,
            spineIndex: position.spineIndex,
            range: NSRange(location: position.charOffset, length: length),
            style: annotationStyle ?? (kind == .highlight ? .highlight : .underline),
            color: annotationColor ?? .yellow,
            note: note.isEmpty ? nil : note
        )
    }
}
