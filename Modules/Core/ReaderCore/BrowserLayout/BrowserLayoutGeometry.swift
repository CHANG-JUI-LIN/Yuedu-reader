import CoreGraphics
import Foundation
import UIKit

/// Phase 2C coordinate contract — five explicit coordinate spaces, each a
/// distinct type so a rect can NEVER be silently used in the wrong space.
/// All conversion goes through NAMED functions in `CoordinateSpace` — raw
/// rect arithmetic across spaces is forbidden.
///
/// | Type             | Space             | Producer                          |
/// |------------------|-------------------|-----------------------------------|
/// | `ParentLocalRect`| parent content    | `BlockBox.frame`                  |
/// | `DocumentRect`   | document absolute | `PageWalker` steps (pre-place)    |
/// | `PageLocalRect`  | page canvas       | `Fragment` / `DisplayItem`        |
/// | `ViewportRect`   | view bounds       | page viewport (== page canvas)    |
/// | `WindowRect`     | window            | `UIView.convert(_:to: window)`    |
///
/// For the paged reader, the page CANVAS equals the actual viewport: origin
/// (0,0) = viewport top-left, size = viewport size. Content sits inside
/// `contentInsets` within it.

/// Parent content-local coordinates (block layout stage).
struct ParentLocalRect: Equatable {
    var rawValue: CGRect

    var minX: CGFloat { rawValue.minX }
    var minY: CGFloat { rawValue.minY }
    var maxX: CGFloat { rawValue.maxX }
    var maxY: CGFloat { rawValue.maxY }
    var width: CGFloat { rawValue.width }
    var height: CGFloat { rawValue.height }
    var origin: CGPoint { rawValue.origin }
    var size: CGSize { rawValue.size }

    static let zero = ParentLocalRect(rawValue: .zero)
}

/// Document-absolute coordinates (walker steps before paging).
struct DocumentRect: Equatable {
    var rawValue: CGRect

    var minX: CGFloat { rawValue.minX }
    var minY: CGFloat { rawValue.minY }
    var maxX: CGFloat { rawValue.maxX }
    var maxY: CGFloat { rawValue.maxY }
    var width: CGFloat { rawValue.width }
    var height: CGFloat { rawValue.height }
    var origin: CGPoint { rawValue.origin }
    var size: CGSize { rawValue.size }

    static let zero = DocumentRect(rawValue: .zero)
}

/// Page canvas-local coordinates (fragments, display items, painting).
/// The page canvas IS the viewport: origin (0,0) = viewport top-left.
struct PageLocalRect: Equatable {
    var rawValue: CGRect

    var minX: CGFloat { rawValue.minX }
    var minY: CGFloat { rawValue.minY }
    var maxX: CGFloat { rawValue.maxX }
    var maxY: CGFloat { rawValue.maxY }
    var width: CGFloat { rawValue.width }
    var height: CGFloat { rawValue.height }
    var origin: CGPoint { rawValue.origin }
    var size: CGSize { rawValue.size }
    var midX: CGFloat { rawValue.midX }
    var midY: CGFloat { rawValue.midY }

    static let zero = PageLocalRect(rawValue: .zero)
    static let null = PageLocalRect(rawValue: .null)

    func contains(_ point: CGPoint) -> Bool {
        rawValue.contains(point)
    }
}

/// The page viewport (== page canvas for the paged reader).
struct ViewportRect: Equatable {
    var rawValue: CGRect
    static let zero = ViewportRect(rawValue: .zero)
}

/// Window coordinates (the final screen space).
struct WindowRect: Equatable {
    var rawValue: CGRect
    static let zero = WindowRect(rawValue: .zero)
}

/// The single, named coordinate-conversion surface. Layout/paint code must
/// NOT add or subtract rects across spaces directly.
enum CoordinateSpace {

    /// LayoutBox: parent content-local → document absolute.
    /// `childParentLocalOrigin` is the child's border-box origin in the
    /// parent's content box; `parentDocumentOrigin` is the parent's content
    /// origin in document space.
    static func parentLocalToDocument(
        _ rect: ParentLocalRect,
        parentDocumentOrigin: CGPoint
    ) -> DocumentRect {
        DocumentRect(rawValue: CGRect(
            x: rect.minX + parentDocumentOrigin.x,
            y: rect.minY + parentDocumentOrigin.y,
            width: rect.width,
            height: rect.height
        ))
    }

    /// Tree assertion: child.documentOrigin == parent.documentContentOrigin +
    /// child.parentLocalOrigin (border-box + parent border/padding).
    static func childDocumentOrigin(
        child: ParentLocalRect,
        parentDocumentContentOrigin: CGPoint,
        parentBorders: EdgeSizes,
        parentPadding: EdgeSizes
    ) -> CGPoint {
        CGPoint(
            x: parentDocumentContentOrigin.x + child.minX + parentBorders.left + parentPadding.left,
            y: parentDocumentContentOrigin.y + child.minY + parentBorders.top + parentPadding.top
        )
    }

    /// Document absolute → page canvas-local.
    /// `pageDocumentOrigin` is this page's document offset (pageIndex × page
    /// content height); `pageContentInset` is the viewport inset.
    static func documentToPageLocal(
        _ rect: DocumentRect,
        pageDocumentOrigin: CGPoint,
        pageContentInset: CGPoint
    ) -> PageLocalRect {
        PageLocalRect(rawValue: CGRect(
            x: rect.minX - pageDocumentOrigin.x + pageContentInset.x,
            y: rect.minY - pageDocumentOrigin.y + pageContentInset.y,
            width: rect.width,
            height: rect.height
        ))
    }

    /// Tree/geometry assertion for every visible fragment:
    /// pageLocalOrigin == documentOrigin - pageDocumentOrigin + pageContentInset.
    static func pageLocalOrigin(
        documentOrigin: CGPoint,
        pageDocumentOrigin: CGPoint,
        pageContentInset: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: documentOrigin.x - pageDocumentOrigin.x + pageContentInset.x,
            y: documentOrigin.y - pageDocumentOrigin.y + pageContentInset.y
        )
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

    static func from(cssRaw: String?) -> BorderStyle {
        switch (cssRaw ?? "solid").lowercased() {
        case "dotted": return .dotted
        case "dashed": return .dashed
        case "none", "hidden": return .none
        default: return .solid
        }
    }
}
