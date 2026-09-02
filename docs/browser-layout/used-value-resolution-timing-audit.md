# BrowserLayout Used-Value Resolution Timing Audit

Date: 2026-08-27

Scope: BrowserLayout only. This audit does not change scanner admission, Lexbor,
PageWalker, or chapter-specific behavior.

## Resolution contract after this phase

1. DOM/CSS cascade retains `CSSLength` values for width, height, max-width,
   margin, padding, and `CSSTextIndent`.
2. `ComputedStyleTreeBuilder` computes font-relative values whose CSS computed
   value is absolute only after the complete cascade has selected the final
   font size.
3. `BoxTreeBuilder` records replaced-element intrinsic data; it does not own
   CSS used sizing.
4. `BlockLayout` resolves each box's used content width from its parent's final
   content width.
5. `InlineFormattingContext`, text-indent, inline replaced sizing, and
   `FloatContext` all receive that same final content width.

## Resolution-site matrix

| Site / property | Specified representation | Computed representation | CGFloat conversion | Reference | Final then? | Recomputed if downstream width changes? | Classification |
|---|---|---|---|---|---|---|---|
| block `width` | `CSSLength` incl. `%`/`em`/`rem`/`auto` | preserved | `BlockLayout.resolveSides` | parent final content width; element font/root font | yes | layout rerun resolves again | Correct |
| `margin-*` | `CSSLength` incl. `%`/`em`/`rem`/`auto` | preserved | `BlockLayout.resolveSides` | parent final content width; element font/root font | yes | yes | Correct |
| `padding-*` | `CSSLength` incl. `%`/`em`/`rem` | preserved | `BlockLayout.resolveSides` | parent final content width; element font/root font | yes | yes | Correct |
| `max-width` | optional `CSSLength` | preserved | `BlockLayout.resolveSides` / replaced sizing | final containing-block content width | yes | yes | Correct after fix; auto margins are recomputed after clamp |
| `font-size` `%`/`em`/`rem` | parsed `CSSLength` transiently | final absolute `CGFloat` | cascade | parent computed font size / root font size | yes for the element cascade | style tree rebuild | Correct |
| `line-height` percentage/length | `pendingLineHeightLength: CSSLength?` during cascade | final absolute `lineHeight` | `ComputedStyle.finalizeLineHeight` | final element font size / root font size | yes | style tree rebuild | Correct after fix |
| unitless `line-height` | `lineHeightMultiplier` | multiplier is retained for inheritance; per-element absolute `lineHeight` | finalization per element | each element's final font size | yes | style tree rebuild | Correct after fix |
| `text-indent` `%`/`em`/`rem` | `CSSTextIndent.length(CSSLength)` | preserved and inherited | `BlockLayout` before IFC creation | owning block's final content width / final font/root | yes | yes | Correct after fix |
| inline line breaking | inline runs + typed styles | no width conversion in BoxTreeBuilder | `InlineFormattingContext` | box final content width, then final float interval | yes | layout rerun | Correct after fix |
| inline/block replaced width and `max-width` | `CSSLength` + intrinsic size | typed style + intrinsic placeholder | `BlockLayout.resolveReplacedSize` | immediate final containing-block content width | yes | yes, on every layout | Correct after fix |
| replaced fixed/`em`/`rem` height | `CSSLength` | preserved | `resolveReplacedSize` | final element/root font bases | yes | yes | Correct |
| replaced percentage height | `CSSLength.percent` | preserved | `resolveReplacedSize` | definite containing-block height, if supplied | only when definite height exists | yes | Corrected: never uses inline width; normal indefinite-height case becomes `auto` |
| float size and placement | resolved block/replaced box | `contentSize`, margin/border boxes | `BlockLayout` then `FloatContext.placeFloat` | parent final content width | yes | full layout rerun | Correct |
| float exclusion | placed float margin boxes | `InlineInterval` | `FloatContext.availableInlineInterval` | final FloatContext width and final float boxes | yes | full layout rerun | Correct |
| border width `px`/`pt`/`em`/`rem` | parsed length | absolute `CGFloat` | cascade | final element font / root font | yes after complete declaration cascade ordering | style tree rebuild | Correct after fix; percentage is invalid and dropped |
| background position `%`/keywords | symbolic fraction | symbolic | canvas paint | final canvas slack | yes | repaint/layout session rebuild | Timing correct, feature incomplete |
| image resource decode `renderWidth` | resource-loader request parameter | bitmap | resource adapter | reader content width | n/a: decode optimization, not layout used value | layout still resizes bitmap | Correct/non-layout |

## Confirmed wrong-reference / wrong-timing sites fixed

### 1. Provisional inline formatting width

Previously non-float inline content and percentage text-indent used
`establishedInlineSize`, propagated before the box's own margin, padding,
border, and used width were resolved. Text could shape wider than its content
box. `InlineFormattingContext` and text-indent now use `box.contentSize.width`.

Polluted capabilities: ordinary prose, decorated headings, nested blocks,
links, ruby, inline images, line count, pagination, selection and hit geometry.

### 2. Replaced elements resolved in BoxTreeBuilder against `renderWidth`

Previously `<img>` and SVG-wrapped raster images converted percentage width to
points while only the global reader width was available. BoxTreeBuilder now
stores intrinsic size only. BlockLayout re-resolves inline and block replaced
elements against the immediate final containing block before line breaking or
float placement.

Polluted capabilities: percentage images, nested galleries, inline replaced
elements, block images, floats, image pagination, exclusion rectangles.

### 3. Percentage replaced height used inline width

The shared `percentBase` previously made `height:50%` use containing width.
`resolveReplacedSize` now accepts an independent definite containing height.
When normal flow has no definite containing height, percentage height is
unresolved and behaves as `auto`; it is never guessed from width.

Polluted capabilities: replaced aspect ratio, float height/exclusion,
pagination.

### 4. `max-width` clamped after margin equation

The old path distributed auto margins, then clamped content width without
re-solving the equation. A `width:100%; max-width:50%; margin:auto` box stayed
left-aligned. Clamp now precedes auto-margin distribution.

Polluted capabilities: centered boxes/images, nested block origins, downstream
containing blocks.

### 5. Line-height resolved before the final winning font-size

An earlier rule such as `line-height:150%` became points immediately; a later
winning `font-size` could not update it. Unitless values also inherited as an
absolute length. The cascade now retains a pending length or unitless
multiplier and finalizes after all declarations. Unitless values recompute on
descendants; length/percentage values inherit as an absolute computed length.

Polluted capabilities: line metrics, ruby ascent/height, inline image line
boxes, pagination.

### 6. Border lengths used hard-coded 17/17/400 bases

`numericWidth` used fixed em/rem/percent bases. Border widths and non-percent
border radius lengths now use the element's final font and root font. Invalid
percentage border widths and unsupported percentage radius are not converted
from a magic 400pt base.

Polluted capabilities: border-box width, decorative box geometry, descendant
containing widths.

## Suspicious or unsupported sites not disguised as fixes

- `inlineContainingSize` remains as a source-compatible Phase 4E0 API
  parameter, but BlockLayout deliberately ignores it. It is no longer a
  geometry reference.
- `BoxTreeBuilder.childContainerWidth` still computes a provisional recursive
  width for tree construction. Replaced sizing and inline layout no longer
  consume it as an authoritative used value. It should be removable in a later
  cleanup, after verifying no build-group behavior relies on it.
- Normal block `height` only applies fixed `.px` at the end of BlockLayout.
  `pt`/`em`/`rem`/percentage block-height need a definite block-size model;
  this is incomplete support, not a remaining early conversion.
- `min-width`, `min-height`, and `max-height` have no ComputedStyle
  representation. They are ignored rather than prematurely resolved.
- Percentage `border-radius` needs both final border-box axes. The current
  scalar radius model does not support it; it is dropped rather than resolved
  against a fabricated 400pt base.
- Explicit `background-size` lengths are not represented. Only
  `auto`/`cover`/`contain` are parsed.
- Background position percentages are timed correctly at canvas paint, but the
  current cover positioning clamps negative slack and the session call does not
  pass the parsed size mode. Those are paint correctness issues, not layout
  used-value timing, and were intentionally not changed in this phase.

## A / B / D diagnostic relevance

- A, decorated heading text missing or escaping its box: **yes, plausibly
  explained** when the heading has margin/padding/border or a nested percentage
  width. The former inline width could exceed the final content box.
- B, orange decorative heading shifted to the box's right side: **yes,
  plausibly explained** by combining percentage margin/width with provisional
  inline shaping. Border paint style fidelity (for example unsupported
  `double`) is separate and is not claimed fixed here.
- D, information-box geometry: **partially**. Nested box width, padding,
  max-width, auto margin, and line breaking are covered by this fix. Any table,
  positioned, flex, or other scanner-unsupported structure remains a separate
  capability and must still fall back under BrowserAuto.

No class, source filename, book title, or spine index participates in any rule.
