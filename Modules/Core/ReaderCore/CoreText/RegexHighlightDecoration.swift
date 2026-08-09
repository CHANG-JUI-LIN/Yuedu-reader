import CoreGraphics
import Foundation
import UIKit

// `RegexHighlightDecoration` is temporarily declared in RegexHighlightEngine.swift while
// the matching engine is being developed in parallel. Keep the drawing-only conveniences here;
// the payload itself can be moved into this file mechanically once those edits have settled.
extension RegexHighlightDecoration {
    var cachedBackgroundImage: UIImage? {
        guard let presentation = style.backgroundImage else { return nil }
        guard let image = ReaderStyleAssetImageCache.shared.image(for: presentation.assetID) else {
            RegexHighlightDecorationImageDiagnostics.reportCacheMiss(
                assetID: presentation.assetID,
                revision: assetRevision
            )
            return nil
        }
        return image
    }
}

enum RegexHighlightDecorationGeometry {
    /// Expands a glyph rect by logical edges in UIKit coordinates.
    ///
    /// In vertical-rl, `top`/`bottom` follow the block axis (right/left) while
    /// `leading`/`trailing` follow the inline axis (top/bottom).
    static func expandedRect(
        glyphRect: CGRect,
        padding: ReaderStyleEdges,
        writingMode: ReaderWritingMode
    ) -> CGRect {
        let top = CGFloat(padding.top)
        let leading = CGFloat(padding.leading)
        let bottom = CGFloat(padding.bottom)
        let trailing = CGFloat(padding.trailing)

        if writingMode.isVertical {
            return CGRect(
                x: glyphRect.minX - bottom,
                y: glyphRect.minY - leading,
                width: max(0, glyphRect.width + top + bottom),
                height: max(0, glyphRect.height + leading + trailing)
            )
        }

        return CGRect(
            x: glyphRect.minX - leading,
            y: glyphRect.minY - top,
            width: max(0, glyphRect.width + leading + trailing),
            height: max(0, glyphRect.height + top + bottom)
        )
    }

    /// Shrinks only the inline edges shared by adjacent fragments. Glyph positions are untouched.
    static func applyingInlineGap(
        to rect: CGRect,
        gap: CGFloat,
        hasPreviousFragment: Bool,
        hasNextFragment: Bool,
        writingMode: ReaderWritingMode
    ) -> CGRect {
        let safeGap = max(0, gap)
        guard safeGap > 0, hasPreviousFragment || hasNextFragment else { return rect }

        let leadingGap = hasPreviousFragment ? safeGap / 2 : 0
        let trailingGap = hasNextFragment ? safeGap / 2 : 0
        if writingMode.isVertical {
            return CGRect(
                x: rect.minX,
                y: rect.minY + leadingGap,
                width: rect.width,
                height: max(0, rect.height - leadingGap - trailingGap)
            )
        }
        return CGRect(
            x: rect.minX + leadingGap,
            y: rect.minY,
            width: max(0, rect.width - leadingGap - trailingGap),
            height: rect.height
        )
    }

    static func combinedEdges(
        padding: ReaderStyleEdges?,
        margin: ReaderStyleEdges?
    ) -> ReaderStyleEdges {
        ReaderStyleEdges(
            top: (padding?.top ?? 0) + (margin?.top ?? 0),
            leading: (padding?.leading ?? 0) + (margin?.leading ?? 0),
            bottom: (padding?.bottom ?? 0) + (margin?.bottom ?? 0),
            trailing: (padding?.trailing ?? 0) + (margin?.trailing ?? 0)
        )
    }
}

enum RegexHighlightImageGeometry {
    static func destination(
        source: CGSize,
        bounds: CGRect,
        mode: ReaderStyleImageContentMode,
        focalX: CGFloat = 0.5,
        focalY: CGFloat = 0.5
    ) -> CGRect {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }

        switch mode {
        case .stretch:
            return bounds
        case .tile:
            return CGRect(
                x: bounds.minX + (bounds.width - source.width) * min(max(focalX, 0), 1),
                y: bounds.minY + (bounds.height - source.height) * min(max(focalY, 0), 1),
                width: source.width,
                height: source.height
            )
        case .fit, .fill:
            let widthScale = bounds.width / source.width
            let heightScale = bounds.height / source.height
            let scale = mode == .fit
                ? min(widthScale, heightScale)
                : max(widthScale, heightScale)
            let size = CGSize(width: source.width * scale, height: source.height * scale)
            let x = bounds.minX + (bounds.width - size.width) * min(max(focalX, 0), 1)
            let y = bounds.minY + (bounds.height - size.height) * min(max(focalY, 0), 1)
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }
}

private enum RegexHighlightDecorationImageDiagnostics {
    private struct Key: Hashable {
        let assetID: UUID
        let revision: UInt64
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var reported = Set<Key>()

    static func reportCacheMiss(assetID: UUID, revision: UInt64) {
        let key = Key(assetID: assetID, revision: revision)
        let shouldReport = lock.withLock { () -> Bool in
            guard !reported.contains(key) else { return false }
            if reported.count >= 256 {
                reported.removeAll(keepingCapacity: true)
            }
            reported.insert(key)
            return true
        }
        guard shouldReport else { return }
        AppLogger.render(
            "regex highlight background image unavailable in draw cache",
            context: [
                "assetID": assetID.uuidString,
                "assetRevision": revision,
            ]
        )
    }
}
