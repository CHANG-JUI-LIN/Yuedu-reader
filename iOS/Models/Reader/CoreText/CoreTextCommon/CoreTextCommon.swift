import Foundation
import CoreText

// MARK: - CoreTextCommon: shared rendering infrastructure
//
// Files in this directory hold code used identically by both
// horizontal and vertical writing modes.
//
// Directory layout:
//
//   CoreTextCommon/                                ← you are here
//   ├── CoreTextCommon.swift                       ← architecture docs
//   ├── String+VerticalNormalization.swift          ← vertical punctuation normalization
//   ├── VerticalLayoutConfig.swift                  ← per-font vert-glyph detection + substitution map cache
//
//   CoreTextHorizontal/
//   └── CoreTextHorizontalLineDrawer.swift
//       • drawLines(of:…) — line-by-line horizontal rendering
//       • isCJKDominant(_:) — CJK/Latin codepoint ratio check
//       • CJK-optimized justification (CTLineCreateJustifiedLine)
//       • Paragraph gap distribution (fill page bottom)
//       • HR divider line drawing
//
//   CoreTextVertical/
//   └── CoreTextVerticalTextRenderer.swift
//       • draw(_:in:) — CTFrameDraw for vertical-rl mode
//
// Shared code (not extracted — lives in the main files):
//
//   CoreTextPaginator.swift:
//     • frameAttributes(for:)     → vertical: kCTFrameProgression.rightToLeft
//     • preparedAttributedString  → vertical: normalizedForVerticalLayout() + CTFont cascade + paragraph style + kCTVerticalFormsAttributeName with ASCII exceptions
//     • gridAlignedContentInsets  → vertical: skip; horizontal: snap to line grid
//     • makeFrame(…)              → shared: creates CTFrame from framesetter
//     • computeLayout()           → shared: pagination loop
//     • applyOrphanControl()      → shared: widow/orphan prevention
//     • extractImages()           → shared: collect image attachments per page
//     • extractBlockRenderables() → shared: collect block decorations per page
//
//   CoreTextPageView.swift:
//     • renderPage()             → dispatch: vertical → CTFrameDraw, horizontal → drawLines
//     • renderPage Phase 0–1     → shared: background, block decorations
//     • renderPage Phase 3       → shared: image drawing (UIImage.draw)
//     • drawBlockRenderables()   → shared: background colors, borders
//     • drawBlockRenderableText()→ shared: explicit block text
//     • drawAttachments()        → shared: block/inline image attachments
//     • drawPageBackground()     → shared: background image
//     • makeInteractionContext() → horizontal only; vertical returns nil
//
//   CoreTextPageEngine.swift:
//     • preloadChapter()         → shared: chapter loading, pagination dispatch
//     • totalPages / page mapping→ shared: page index calculation
//     • theme updates            → shared: color/theme propagation

/// Vertical-vs-horizontal writing mode decision point.
/// Used throughout the paginator and page view to branch rendering logic.
typealias WritingMode = ReaderWritingMode
