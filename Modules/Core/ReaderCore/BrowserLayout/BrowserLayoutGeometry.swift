import CoreGraphics
import Foundation
import UIKit

/// Phase 2C coordinate contract — one explicit semantics per layer. A raw
/// `CGRect` is NEVER passed across layers; each layer's rect carries its
/// coordinate space in the type, so a document rect cannot be mistaken for a
/// page-local rect at compile time.
///
/// | Type         | Layer                       | Semantics                                  |
/// |--------------|-----------------------------|--------------------------------------------|
/// | `LocalRect`  | `BlockBox.frame`            | parent content-local (layout stage)        |
/// | `DocumentRect`| `PageWalker` Step (pre-place)| document absolute (root content origin)   |
/// | `PageRect`   | `Fragment` / `DisplayItem`  | page canvas-local (viewport coordinates)   |
///
/// A `PageRect` is measured against the page CANVAS (the full viewport),
/// NOT the content rect — the canvas equals the actual page viewport.

/// Parent content-local coordinates (block layout stage).
struct LocalRect: Equatable {
    var rect: CGRect

    var minX: CGFloat { rect.minX }
    var minY: CGFloat { rect.minY }
    var maxX: CGFloat { rect.maxX }
    var maxY: CGFloat { rect.maxY }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var origin: CGPoint { rect.origin }
    var size: CGSize { rect.size }

    static let zero = LocalRect(rect: .zero)

    func offsetBy(dx: CGFloat, dy: CGFloat) -> LocalRect {
        LocalRect(rect: rect.offsetBy(dx: dx, dy: dy))
    }
}

/// Document-absolute coordinates (walker steps before paging).
struct DocumentRect: Equatable {
    var rect: CGRect

    var minX: CGFloat { rect.minX }
    var minY: CGFloat { rect.minY }
    var maxX: CGFloat { rect.maxX }
    var maxY: CGFloat { rect.maxY }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var origin: CGPoint { rect.origin }
    var size: CGSize { rect.size }

    static let zero = DocumentRect(rect: .zero)

    func offsetBy(dx: CGFloat, dy: CGFloat) -> DocumentRect {
        DocumentRect(rect: rect.offsetBy(dx: dx, dy: dy))
    }
}

/// Page canvas-local coordinates (fragments, display items, painting).
/// The page canvas IS the viewport: origin (0,0) = viewport top-left,
/// size = viewport size. Content sits inside `contentInsets` within it.
struct PageRect: Equatable {
    var rect: CGRect

    var minX: CGFloat { rect.minX }
    var minY: CGFloat { rect.minY }
    var maxX: CGFloat { rect.maxX }
    var maxY: CGFloat { rect.maxY }
    var midX: CGFloat { rect.midX }
    var midY: CGFloat { rect.midY }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    var origin: CGPoint { rect.origin }
    var size: CGSize { rect.size }

    static let zero = PageRect(rect: .zero)
    static let null = PageRect(rect: .null)

    func offsetBy(dx: CGFloat, dy: CGFloat) -> PageRect {
        PageRect(rect: rect.offsetBy(dx: dx, dy: dy))
    }

    func contains(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }
}

/// One edge of a border box.
struct BorderEdge: Equatable {
    var width: CGFloat = 0
    var color: UIColor = .black
    var style: BorderStyle = .solid

    static let zero = BorderEdge()

    var isVisible: Bool { width > 0 && style != .none }
}

enum BorderStyle: Equatable {
    case none
    case solid
    case dotted
    case dashed

    /// The visual pattern is applied by the painter; this keeps the model
    /// style-aware without leaking CGContext dash arrays into layout.
    static func from(cssRaw: String?) -> BorderStyle {
        switch (cssRaw ?? "solid").lowercased() {
        case "dotted": return .dotted
        case "dashed": return .dashed
        case "none", "hidden": return .none
        default: return .solid
        }
    }
}
