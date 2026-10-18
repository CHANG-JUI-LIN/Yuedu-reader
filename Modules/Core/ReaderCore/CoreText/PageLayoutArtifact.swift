import CoreGraphics
import CoreText
import Foundation

/// Final Core Text layout object and derived line geometry for one page.
///
/// The artifact is created after page ranges and float notches are finalized.
/// Extractors and drawing consume this exact frame instead of shaping the same
/// page again.
struct PageLayoutArtifact: Sendable {
    let range: CFRange
    @LayoutShared var frame: CTFrame
    let lineOrigins: [CGPoint]
}
