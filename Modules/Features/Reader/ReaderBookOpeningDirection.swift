import CoreGraphics
import Foundation

// MARK: - ReaderBookOpeningDirection
//
// Which side the book's spine is on, so the open animation unfolds toward
// the correct edge:
//
//   - `.leftSpine`  (右開書 / 西式 / LTR): 翻開時左側是書脊,封面從右向左翻
//     等同於一本裝訂在左側的書,打開時頁面從左往右展開。
//   - `.rightSpine` (左開書 / 日式直排 / RTL): 書脊在右側,封面從左向右翻,
//     打開時頁面從右往左展開。
//
// 選取依據:直排寫作模式 (verticalRTL) 或 EPUB page-progression rtl 視為
// 右側書脊;否則左側書脊。

enum ReaderBookOpeningDirection: Equatable {
    case leftSpine
    case rightSpine

    /// 依書本寫作模式與 EPUB 方向決定開書方向。
    static func resolve(
        writingMode: ReaderWritingMode,
        pageProgressionIsRTL: Bool
    ) -> ReaderBookOpeningDirection {
        let rtl = writingMode.isVertical || pageProgressionIsRTL
        return rtl ? .rightSpine : .leftSpine
    }
}

// MARK: - ReaderBookOpeningPose

/// Direction-aware, reversible book-opening state. Opening and interactive
/// closing both evaluate this same model, so a gesture can stop or reverse at
/// any point without jumping between separately queued animations.
///
/// The pose models a physical paperback: the live reader page scales with
/// the growing card (small to large, always rendering real content), the
/// cover hinges just past perpendicular across most of the gesture without
/// being clipped by the card, and a soft spine shadow on the paper peaks
/// while the cover hovers mid-lift.
struct ReaderBookOpeningPose: Equatable {
    /// Front-cover hinge in unit coordinates (`0` = left, `1` = right).
    let coverAnchorX: CGFloat
    /// Signed 3D rotation around the Y axis. Spine sides are exact mirrors.
    let coverRotationY: CGFloat
    /// Opacity of the rotating front cover. Back-face culling already hides
    /// it past 90°; this is the trailing safety fade.
    let coverOpacity: CGFloat
    /// Spine shadow that builds during the unfold and fades at both endpoints.
    let spineShadowOpacity: CGFloat

    /// Peak hinge angle (~108°): just past perpendicular, so the cover stays
    /// visible for most of the motion and back-face culling retires it.
    private static let maxCoverRotation: CGFloat = .pi * 0.60

    static func interpolate(
        progress: CGFloat,
        direction: ReaderBookOpeningDirection
    ) -> ReaderBookOpeningPose {
        let p = ReaderCardTransitionMath.clampProgress(progress)
        // The card lifts and grows first (frame/shadow phases live in
        // ReaderCardVisualState); the cover starts hinging shortly after and
        // keeps turning until nearly the end of the transition.
        let unfold = ReaderCardTransitionMath.phase(p, in: 0.14...0.90)
        let coverFade = ReaderCardTransitionMath.phase(p, in: 0.84...0.97)

        let anchorX: CGFloat
        let rotationSign: CGFloat
        switch direction {
        case .leftSpine:
            anchorX = 0
            rotationSign = -1
        case .rightSpine:
            anchorX = 1
            rotationSign = 1
        }

        // Tied to the unfold (not raw progress) so paper is flat and unshaded
        // exactly when the cover is at rest; exact zeros at the endpoints
        // because sin(π·x) leaves floating-point residue.
        let spineShadow: CGFloat
        if unfold <= 0 || unfold >= 1 {
            spineShadow = 0
        } else {
            spineShadow = 0.35 * sin(.pi * unfold)
        }

        return ReaderBookOpeningPose(
            coverAnchorX: anchorX,
            coverRotationY: rotationSign * maxCoverRotation * unfold,
            coverOpacity: 1 - coverFade,
            spineShadowOpacity: spineShadow
        )
    }
}
