import CoreGraphics
import Foundation
import UIKit

enum DisplayItem {
    case text(DisplayTextItem)
    case fill(DisplayFillItem)
    case image(DisplayImageItem)
}
struct DisplayTextItem { let range: NSRange; let rect: CGRect; let baselineY: CGFloat; let font: UIFont; let color: UIColor }
struct DisplayFillItem { let rect: CGRect; let color: UIColor; let cornerRadius: CGFloat }
struct DisplayImageItem { let rect: CGRect; let source: String; let alt: String? }

struct DisplayList {
    let items: [DisplayItem]
    static let empty = DisplayList(items: [])
}

/// Flattens a page's fragment tree (groups are recursive) into a flat draw list.
/// Coordinates are page-local already. This is the boundary a future draw phase
/// renders with UIKit/CoreGraphics.
enum DisplayListBuilder {
    static func build(for page: PageFragments) -> DisplayList {
        var items: [DisplayItem] = []
        collect(page.fragments, into: &items)
        return DisplayList(items: items)
    }

    private static func collect(_ fragments: [Fragment], into items: inout [DisplayItem]) {
        for fragment in fragments {
            switch fragment {
            case .text(let t):
                items.append(.text(DisplayTextItem(range: t.range, rect: t.rect, baselineY: t.baselineY, font: t.font, color: t.color)))
            case .fill(let f):
                items.append(.fill(DisplayFillItem(rect: f.rect, color: f.color, cornerRadius: f.cornerRadius)))
            case .image(let i):
                items.append(.image(DisplayImageItem(rect: i.rect, source: i.source, alt: i.alt)))
            case .group(let children):
                collect(children, into: &items)
            }
        }
    }
}
