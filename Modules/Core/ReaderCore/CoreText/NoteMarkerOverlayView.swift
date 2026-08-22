import UIKit

// MARK: - Geometry

/// 筆記圓圈標記的幾何。分頁與捲動兩條渲染路徑共用同一份，避免兩邊各長一套尺寸。
enum NoteMarkerGeometry {
    /// 圓圈直徑。比 44pt 小，所以命中判定會另外把它撐到 `minimumTapSize`。
    static let diameter: CGFloat = 22
    /// 圓圈與被標註文字之間的間距。
    static let gap: CGFloat = 3
    /// 命中範圍：圓圈本身只有 22pt，手指按不準，判定時撐到 HIG 的最小點擊尺寸。
    static let minimumTapSize: CGFloat = 44

    /// 由被標註文字第一個字的 rect，算出圓圈要畫在哪。
    ///
    /// 橫排：文字起點正上方，圓心對齊起點左緣（一半壓在左邊界外，和設計稿一致）。
    /// 直排：文字起點右側，圓心對齊該欄頂端——直排的「上方」在版面上是右邊。
    static func badgeRect(anchoredTo anchor: CGRect, isVertical: Bool) -> CGRect {
        let size = CGSize(width: diameter, height: diameter)
        if isVertical {
            return CGRect(
                origin: CGPoint(
                    x: anchor.maxX + gap,
                    y: anchor.minY - diameter / 2
                ),
                size: size
            )
        }
        return CGRect(
            origin: CGPoint(
                x: anchor.minX - diameter / 2,
                y: anchor.minY - diameter - gap
            ),
            size: size
        )
    }

    /// 命中範圍：圓圈置中撐大到 `minimumTapSize`。
    static func tapRect(for badgeRect: CGRect) -> CGRect {
        let inset = (minimumTapSize - diameter) / 2
        return badgeRect.insetBy(dx: -inset, dy: -inset)
    }
}

// MARK: - Overlay

/// 畫「這段有筆記」的圓圈標記。位置由 `CoreTextAnnotationRenderer.noteMarkers` 算好後交進來。
///
/// 和 `InteractionOverlayView` 分開的原因：標註 overlay 是以 (樣式, 顏色) 分層重用的，
/// 而筆記圓圈屬於單一標註、必須畫在所有標註層之上，混進去會被顏色分層切碎。
final class NoteMarkerOverlayView: UIView {
    var markers: [CoreTextAnnotationRenderer.NoteMarker] = [] {
        didSet {
            guard markers != oldValue else { return }
            isHidden = markers.isEmpty
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // 命中判定由宿主 view 在 handleTap 裡做（它要同時和連結、圖片、註解競爭優先序），
        // 這層只負責畫。
        isUserInteractionEnabled = false
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for marker in markers {
            Self.draw(badgeIn: marker.badgeRect, in: ctx)
        }
    }

    /// 圓底 ＋ 內縮圓角方塊。用 `label` 的透明度取色，所以夜間主題與各種閱讀底色都能跟著走。
    static func draw(badgeIn badgeRect: CGRect, in ctx: CGContext) {
        let circle = UIBezierPath(ovalIn: badgeRect)
        UIColor.label.withAlphaComponent(0.10).setFill()
        circle.fill()
        UIColor.label.withAlphaComponent(0.18).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let glyphSide = badgeRect.width * 0.34
        let glyphRect = CGRect(
            x: badgeRect.midX - glyphSide / 2,
            y: badgeRect.midY - glyphSide / 2,
            width: glyphSide,
            height: glyphSide
        )
        let glyph = UIBezierPath(roundedRect: glyphRect, cornerRadius: glyphSide * 0.28)
        UIColor.label.withAlphaComponent(0.45).setFill()
        glyph.fill()
    }
}
