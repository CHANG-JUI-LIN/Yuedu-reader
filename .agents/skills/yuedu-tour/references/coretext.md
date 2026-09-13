# Yuedu Coretext

Paths below are relative to the repository root. Read only the section relevant to the task.

## CoreText Pitfalls

### Paged Layout

- Margin flow is `ReaderConfig.shared` / `GlobalSettings.pageMarginH/V` -> `ReaderRenderSettings.contentInsets` -> `CoreTextPaginator.paginate(contentInsets:)` -> `ChapterLayout.contentInsets` -> `CoreTextPageView.draw()`. Do not bypass this chain.
- Footer layout settings are split: `ReaderConfig.footerBottomPadding` is the literal SwiftUI footer `.padding(.bottom, value)` and must not silently add `windowSafeBottom`; `ReaderConfig.footerTextGap` belongs in the CoreText bottom inset as the reserved gap between the last text line area and the footer.
- Reader layout setting changes must both update `EPUBPageRenderer.updateRenderSettings(...)` and invalidate the active engine. The engine's `onChapterReady` callback should replace the current page with `engine.pageViewController(at:)` after invalidation; otherwise the old VC can remain visible until navigation or reader re-entry.
- Full-page bottom alignment and orphan/widow control are competing goals. If the product wants every normal text page filled to the last configured line, keep the usable content height aligned to the line-height grid and do not move a previous page's last line forward just to avoid orphan/widow lines.
- `CTFrameGetLineOrigins` returns coordinates relative to the path bounding rect, not absolute context coordinates. Add `contentMinX` and `contentMinY` in `drawLines`.
- After `invalidateLayout()`, call the engine's `onChapterReady` callback. Handlers must fetch a fresh view controller with `engine.pageViewController(at:)`; do not reuse a stale VC.
- EPUB CSS parsing supports `margin` (shorthand), `margin-left`, `margin-right`, `margin-top`, `margin-bottom`, `padding` (shorthand), `padding-left`, `padding-right`, `text-indent`, `width`, `height`. Percentage values for these properties resolve against `config.renderWidth` (content width), not font size, matching the CSS spec for containing-block-relative percentages.
- `CoreTextPageView.drawLines` uses `isCJKDominant()` to detect script per line. CJK-dominant non-last lines with coverage > 0.85 are justified via `CTLineCreateJustifiedLine`; Latin/English-dominant lines use natural alignment to prevent CTFrame from stretching word spacing excessively. When adding justification logic, do not apply CJK-style justification to Latin text without hyphenation support.
- `CoreTextPageEngine.resolveInternalLink` ignores `kindle:` scheme links. EPUB TOC entries may reference `kindle:embed:...` URIs that cannot resolve to EPUB content; the resolver returns `nil` silently instead of attempting path resolution.

### EPUB CSS Rendering Pipeline

Two parallel paths both produce NSAttributedString; keep them in sync when changing CSS support:

| Path | Builder | Converter | Renderer |
| --- | --- | --- | --- |
| Legacy (paged engine preload) | `HTMLAttributedStringBuilder.build()` | (none — direct NSAttributedString) | `CoreTextPageView.drawLines` |
| RenderableNode (EPUB builder) | `HTMLAttributedStringBuilder.buildStyledAST()` | `HTMLStyledASTRenderableNodeConverter` → `RenderableNode` | `NodeAttributedStringRenderer` |

Both paths share `CSSParser`, `HTMLBuilderDOMParser`, `HTMLBuilderStyleResolver`, `HTMLCSSPropertyApplierRegistry`, and `ResolvedStyle`. Changing `ResolvedStyle` fields or CSS resolution affects both. Adding a field to `RenderStyle` also requires the converter (`RenderStyle.from`) and `NodeAttributedStringRenderer` updates.

The legacy path calls `build()` which internally calls `buildStyledAST()` + `coreTextRenderer.render()`. The RenderableNode path calls `buildStyledAST()` separately then converts to `[RenderableNode]` and renders via `NodeAttributedStringRenderer`.

### EPUB TOC Panel

- The reader TOC panel (`ReaderMenuView`) should prioritize `session.tocEntries` (from `toc.ncx` / `nav.xhtml`) over `session.chapters` (spine). See `ReaderView.applyPublicationSession`.
- `tocEntries` come from `PublicationSession.flattenTableOfContents(publication.manifest.tableOfContents)`. Each `EPUBTocEntry` has `href`, `title`, `level`.
- Map tocEntry href to spine index via `session.chapters` href matching. Strip `#fragment` from tocEntry hrefs before matching.
- Only fall back to spine chapter list when `tocEntries` is empty.
- Deduplicate consecutive identically-titled entries in the fallback path (e.g. multiple "Contents" pages from spine-only items not in toc.ncx).

### :first-letter / Drop Cap

- CSS `:first-letter` rules are parsed separately in `CSSParser.parseWithFirstLetter`. The pseudo-selector suffix is stripped, and the base selector is matched normally. Rules land in `config.firstLetterRules` → `ParsedHTML.firstLetterRules`.
- Matching happens in `HTMLAttributedStringBuilder.resolvedStyle`. Only `font-size`, `font-weight`, and `color` are resolved; `float`, `line-height`, and `margin` are intentionally ignored for the simplified implementation.
- The resolved values (`firstLetterFontSizeMultiplier`, `firstLetterFontWeight`, `firstLetterColor`) flow through both pipelines. In `renderBlockElement` / `renderBlock`, apply to the first typographic letter unit via `firstLetterRange(in:)`.
- `firstLetterRange` skips leading whitespace and punctuation to find the actual first letter; the returned range includes adjacent punctuation (e.g. `"W` for left-quote + W).
- The oversized first-letter glyph will be clipped unless `maximumLineHeight` is relaxed. After applying the first-letter font, check if `maximumLineHeight` is too small and set it to `0` (no ceiling) if the drop cap needs more room.
- Do NOT chase full `float: left` text wrapping in the simplified version. The first letter appears as a large inline glyph at the paragraph start.

### Nested Block Margin Accumulation

- CoreText uses a single frame for all text. Paragraph `headIndent` is measured from the frame edge, not from a parent container's content edge. Parent block `margin-left` does NOT automatically compound into child block indentation.
- `ResolvedStyle.inheritedBlockMarginLeft` accumulates ancestor block margins. In `resolvedStyle`, block elements add their own `marginLeft` to the inherited value. `makeParagraphStyle` and `NodeAttributedStringRenderer.applyBlockStyle` add `inheritedBlockMarginLeft` to `headIndent`.
- `RenderContext.inheritedBlockMarginLeft` propagates this through the RenderableNode path.

### HR Divider Rendering

- `<hr>` elements produce an `HRDividerStyle` stored in `hrDividerAttribute` on a zero-width NSAttributedString line.
- `CoreTextPageView.drawLines` draws the line. The extended `HRDividerStyle` carries `ruleWidth`, `ruleWidthPercent`, `marginLeft`, `marginRight`, `inheritedBlockMarginLeft`, `alignment`, and `isHorizontallyCentered`.
- The drawing code computes available width from contentWidth minus margins, resolves percentage width, and positions the line per text-align/center.
- The legacy path sets these fields in `makeHRDivider` from `ResolvedStyle`. The RenderableNode path sets them in `NodeAttributedStringRenderer.horizontalRule` from `RenderStyle` + `RenderContext`.
- `RenderStyle` must carry `marginRight` and `rawWidthPercent` for the RenderableNode path to work.

### Link Tap Hit-Testing

- `CTLineGetStringIndexForPosition` returns the nearest character even for taps far to the right of the text. This makes blank space trigger links and blocks page-turning on TOC pages.
- In `CoreTextPageView.stringIndex(at:in:)` and `CoreTextChunk.stringIndex(atLocalPoint:)`, check that the tap X coordinate is within `[lineOrigin.x - tolerance, lineOrigin.x + lineWidth + tolerance]` before looking up the character index.
- Use `CTLineGetTypographicBounds` to get the line's actual typographic width. Return `nil` when the tap is outside text bounds so the parent gesture (page turn) can handle it.

### Font Trait Fallback

- When an EPUB embedded font or user-imported font does not support the requested bold/italic traits, `withSymbolicTraits` fails silently and the traits are lost.
- In both `HTMLAttributedStringBuilder.styledEmbeddedFont` and `NodeAttributedStringRenderer.applyTraits`, when the target font cannot satisfy the requested traits, fall back to the system font with the correct weight/italic.

### Underline / Strikethrough

- Semantic HTML tags `u`/`ins` (underline) and `s`/`strike`/`del` (strikethrough) are mapped in `resolvedStyle` tag-based checks, independent of CSS.
- `ResolvedStyle.underline` and `.strikethrough` propagate through `inheritedStyle` and `baseTextAttributes` sets `.underlineStyle` / `.strikethroughStyle` on the attributed string.
- `RenderStyle` and `NodeAttributedStringRenderer.RenderContext` mirror these fields for the RenderableNode path.
- CoreText does NOT automatically draw underlines or strikethroughs; visual rendering requires manual drawing in the page view which is not yet implemented.

### Stable Reading Position

- Do not treat `globalPage` as stable content identity. Unloaded chapters may be estimated as one page while offsets rebuild, so `globalPage` can shift.
- Use `(spineIndex, charOffset)` as the durable position identity. This matches `EPUBPageRenderer` progress persistence and avoids wrong previous-page behavior near chapter boundaries.
- Keep `globalPage` as derived display/navigation state, not the source of truth for content identity.

### Reader Fonts

- User-imported reader fonts live behind `UserFontStorageManager`, `GlobalSettings.userFonts`, and `GlobalSettings.selectedReaderFontPostScript`.
- Gate the font picker with `ReadingBook.allowsUserSelectedReaderFont`, not only `BookPipelineKind`, because online books resolve to `.html` but should still expose user fonts.
- Apply user fonts through `UserReaderFontResolver` for TXT and online TXT fallback. For online HTML, pass the selected PostScript name as `HTMLAttributedStringBuilder.Config.fontFamilyName` so it acts as the default font while CSS `font-family` can still override it.
- Reflowable EPUB exposes the existing reader font picker. An explicitly selected font overrides authored families through the EPUB font resolvers before measurement, preserving size/bold/italic; nil restores publication fonts. Fixed-page/image content remains non-reflowable. Use the immutable ReaderRenderSettings.fontPostScriptName snapshot, not mutable globals during chapter builds.

### Reader Settings UI

- Reader UI development should use native SwiftUI/UIKit presentation by default for navigation bars, toolbar items, dismiss/close buttons, sheets, menus, pickers, and standard controls. Do not hand-roll custom circular header buttons, fake navigation bars, or bespoke chrome unless the user explicitly asks for a custom visual treatment.
- Reader settings should remain a SwiftUI/system-control surface. Prefer system `Picker`, `Menu`, `Stepper`, `Slider`, `Toggle`, `Button`, and SF Symbols; customize with tint, spacing, and grouping before creating custom controls.
- Keep `ReaderSettingsView` navigation actions system-native by default. Do not replace the standard inline title and `完成` toolbar button with custom circular header buttons unless the user explicitly requests that specific custom header.
- Keep high-frequency settings visible and low-frequency settings compact: reading mode can stay segmented, while multi-option page-turn animation is better as a `Menu` or another compact system selection.
- Do not expose vertical page margin controls in reader settings unless the product explicitly reopens that setting. The visible page margin setting is horizontal only.
- Keep line height, letter spacing, paragraph spacing, horizontal page margin, and explicit footer spacing controls together in one layout/accessibility section. If the UI exposes a `自訂` toggle for that section, disabling it should hide the advanced sliders and restore the default values.
- Footer spacing controls should be literal and inspectable: "bottom footer distance" maps to the footer view's bottom padding, while "text to footer" maps to the reader content bottom inset. Do not combine the bottom footer slider with safe-area compensation unless the UI label says so.
- Reader settings preview cards must keep stable dimensions. Let font size, line spacing, and theme update inside a fixed preview frame, but do not bind preview card height or padding to live reader margins; otherwise changing text settings makes the whole settings sheet jump.
- Theme changes in paged CoreText must refresh the visible page immediately. If the current page index does not change, call the engine theme update path and replace the current page view controller; otherwise the reader may only show the new colors after exiting and re-entering.

### Reader Overlay Controls

- Keep the bottom reader menu in `ReaderBottomControlBar` as a presentational SwiftUI component. `ReaderView` should own reader navigation, chapter state, download/source/TTS sheets, and persistence; pass only bindings, display strings, derived booleans, and callbacks into the bar.
- Local bottom-bar UI state such as brightness expansion and slider draft progress can live inside `ReaderBottomControlBar`; actions that mutate reading position, source state, brightness synchronization, or sheets should call back into `ReaderView`.

### TTS Media Controls

- For reader TTS system media controls, keep `AVAudioSession`, `MPNowPlayingInfoCenter`, and `MPRemoteCommandCenter` ownership centralized in `TTSCoordinator`; lower-level engines such as `TTSManager` and `HTTPTTSEngine` should only play, pause, resume, and stop their audio source.
- The main app `Info.plist` must include `UIBackgroundModes` with `audio`; verify the built `.app/Info.plist`, not only project build settings, because array-valued Info.plist keys may not be generated correctly from scalar `INFOPLIST_KEY_*` settings.
- Activate the audio session only when TTS playback starts. Use `.playback` with `.spokenAudio`; avoid `.duckOthers` or `.mixWithOthers` when TTS should appear as the active Control Center media source.
- Remote command handlers should dispatch back to the main queue before touching `AVSpeechSynthesizer`, `AVPlayer`, published state, or reader callbacks. Pause should keep the audio session and Now Playing card alive with playback rate `0`; stop should clear Now Playing and deactivate the session.
- `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` are global system surfaces, not per-view objects. If settings test playback and reader chapter playback each create a `TTSCoordinator`, the active playback coordinator must explicitly claim ownership and re-register remote commands on every start/resume. Only the active owner should write Now Playing, disable commands, clear Now Playing, or deactivate the audio session; otherwise a settings-test coordinator can leave the chapter player visible on Dynamic Island but unable to pause from system controls.
- Prefer HTTP TTS audio playback over `AVSpeechSynthesizer` for Control Center, lock screen, Dynamic Island, and reliable pause/resume. `CustomHTTPProvider` reads `GlobalSettings.httpTtsUrlTemplate`; templates support `{{text}}`, `{{title}}`, and `{{speakSpeed}}`.
- For local backend testing from a real iPhone, do not use `localhost`; use the Mac's LAN IP, for example `http://<mac-lan-ip>:5001/tts?text={{text}}`. The app `Info.plist` already allows arbitrary loads and local networking.
- Treat TTS previous/next controls as segment controls inside `HTTPTTSEngine`, not reader page controls. The engine should publish current segment index/total/text through `TTSCoordinator`, and `ReaderView` can use the current segment text to drive CoreText playback highlighting.
- CoreText TTS highlighting should reuse existing text-selection geometry where possible. Add a non-interactive overlay behind the normal selection overlay, use yellow fill with no handles, and map the current segment text into the visible page range before calling selection-rect logic. This is whole-segment highlighting; word-level karaoke needs provider timestamps or a separate time-to-index estimator.
- `CustomHTTPProvider` resolves `{{speakSpeed}}` as an Edge TTS style percentage string such as `+0%`, `+30%`, or `-20%`, not the earlier `0.50` float. Keep HTTP backend templates and settings copy aligned with that format.
- `HTTPTTSEngine` should merge punctuation-only chunks into the previous speakable chunk; `containsSpeakableContent` uses letters and digits as the speakable-content test.
- Segment skip actions should publish the new segment index before starting playback and a background task, otherwise the panel or system media surfaces can briefly show the old segment.

### Writing Mode

- `ReaderWritingMode` is a global reader setting persisted by `GlobalSettings.readerWritingMode`.
- Do not expose writing direction as a general user setting in the reader settings UI. Treat vertical writing as a format/content capability: current vertical mode is for paged CoreText TXT and online books only; EPUB and scroll mode resolve to horizontal.
- Paged vertical mode flows through `ReaderRenderSettings.writingMode` -> `PaginationRequest.writingMode` -> `CoreTextPaginator.paginate(... writingMode:)` -> `ChapterLayout.writingMode` -> `CoreTextPageView`.
- `CoreTextPaginator` applies `kCTVerticalFormsAttributeName` and creates frames with `kCTFrameProgressionAttributeName = CTFrameProgression.rightToLeft`. Use `CoreTextPaginator.makeFrame(...)` for any new CoreText frame in this pipeline.
- Vertical page text interaction supports tap hit-testing, internal links, selection rects, and underline overlays through `CoreTextPageView` vertical geometry. Do not reuse horizontal math: vertical `CTLineGetStringIndexForPosition` uses X as inline advance, while column block extents come from ascent/descent.
- App-introduced page/chunk break offsets should pass through `CJKTypographyProcessor.protectedLineBreakOffset(...)` to avoid splitting surrogate pairs or forcing forbidden CJK punctuation at line/page boundaries.
- Before larger CoreText changes, read `docs/coretext/README.md` and the linked vertical-writing / interaction notes.

### Vertical CoreText Rendering (vertical-rl)

Vertical mode wiring: `ReaderWritingMode.verticalRTL` → `kCTFrameProgressionAttributeName = rightToLeft` + `kCTVerticalFormsAttributeName = true`. `CoreTextPageView.renderPage` dispatches to `drawVerticalFrame` (calls `CTFrameDraw`) instead of `drawHorizontalFrame` (line-by-line drawing).

#### Coordinate System Differences

In vertical CoreText, `CTLineGetTypographicBounds` and `CTLineGetStringRange` return values in **different axes** than horizontal mode:

| Property | Horizontal | Vertical-rl |
|---|---|---|
| `lineOrigin.x` | Text left edge | Column position in block direction (RTL: rightmost = highest x) |
| `lineOrigin.y` | Baseline Y | Position along column in inline direction (top-to-bottom) |
| Typographic `width` | X extent of line | Y extent of column (inline direction) |
| Typographic `ascent` | Y extent above baseline | **X extent** toward block-start (rightward in RTL) |
| Typographic `descent` | Y extent below baseline | **X extent** toward block-end (leftward in RTL) |

**Critical**: `ascent` and `descent` from `CTLineGetTypographicBounds` / `CTRunGetTypographicBounds` are **X-axis values** in vertical mode. Never add them to Y coordinates. CTRunDelegate callbacks follow the same axis mapping: `getAscent`/`getDescent` → block (X), `getWidth` → inline (Y).

**Negative descent**: In vertical mode, `CTRunDelegate` runs (especially images with large block-direction extents) can return **negative descent values**. Example: image ascent=189, descent=-167.4. Both values may point in the same direction relative to baseline. Use `abs(lineDescent)` for total block extent: `lineAscent + abs(lineDescent)`.

#### Paragraph Style Limitations

CoreText's `NSParagraphStyle` properties have **different semantics** in vertical mode. Properties that work in the **block direction (X)** have no inline-direction equivalents:

| Property | Horizontal effect | Vertical-rl effect |
|---|---|---|
| `paragraphSpacingBefore` | Space above paragraph (Y) | **Ignored** (X-direction spacing, unreliable) |
| `firstLineHeadIndent` | Indent from left (X) | **Ignored** for Y positioning |
| `headIndent` / `tailIndent` | Left/right margins (X) | Block-direction margins |
| `textAlignment` | Horizontal alignment | **Works**: `.right` → bottom-aligned (inline-end) |
| `minimumLineHeight` | Min line height (Y) | Min column height (Y inline) — **works for Y constraints** |
| `paragraphSpacing` | Space after paragraph (Y) | Block-direction spacing (X) |
| `lineSpacing` | Space between lines (Y) | Block-direction spacing (X) |

**CSS `margin-top` is NOT supported in vertical CoreText.** CSS `margin-top` maps to `paragraphSpacingBefore` which CoreText ignores in vertical-rl for inline (Y) positioning. Do not try to work around this with:
- `NSBaselineOffsetAttributeName` — shifts baseline in block (X) direction, not inline (Y)
- `CTRunDelegate` spacer characters — disrupt pagination and image extraction
- `firstLineHeadIndent` — no effect on Y position

The only working inline-direction positioning via paragraph style is `textAlignment` (right=bottom, center=middle, left/natural=top).

#### Extract Block Renderables — Vertical Mode

`CoreTextPaginator.extractBlockRenderables` merges per-line rects into block-level rects. In vertical mode, the original code added `lineAscent` (X-direction) to `adjustedOrigin.y`, producing nonsense Y coordinates. Fix:

- `uiY = renderSize.height - adjustedOrigin.y` (column top, no ascent term)
- `lineHeight = lineWidth` (inline/Y extent, not ascent+descent)
- `rectX = adjustedOrigin.x - rectW / 2` (center block on column baseline)
- In `blockImageRect`, always center image horizontally in vertical mode (override CSS alignment)

#### ImageRunInfo / CTRunDelegate

`extractImages` and `makeBlockImageAttachment` cast ALL `CTRunDelegate` refCons to `ImageRunInfo` via `Unmanaged<ImageRunInfo>.fromOpaque`. Any new non-image CTRunDelegate runs **must** be marked with `HTMLAttributedStringBuilder.spacerRunAttribute` and guarded at both sites, or they will crash when the refCon casting fails.

#### Vertical Font Cascade and Normalization

`preparedAttributedString` in `CoreTextPaginator` applies:
1. Half-to-full-width bracket conversion (1:1 length-preserving via `replaceOccurrences` on `mutableString`)
2. Per-font vertical substitution map (`VerticalLayoutConfig` — detects glyphs lacking vertical alternates)
3. CTFont cascade: PingFang → Songti TC → Kaiti TC → Heiti TC
4. Default paragraph style vertical defaults (firstLineHeadIndent=2em, paragraphSpacing=0.8em, lineSpacing=0.3em)
5. `kCTVerticalFormsAttributeName = true` globally, removed for ASCII `[a-zA-Z0-9\\s]+`

#### Vertical Links, Selection, and Underlines

- `CoreTextPageView.makeInteractionContext()` is shared by horizontal and vertical pages. Vertical hit-testing first chooses a column by X, computes inline advance from the column top, then calls `CTLineGetStringIndexForPosition(line, CGPoint(x: advance, y: 0))`.
- Vertical selection rects use the same string ranges as horizontal selection but return tall column-local rects. Keep link taps, long-press selection, handle dragging, TTS highlights, and underline bookmarks on this common range geometry.
- `InteractionOverlayView.drawsVerticalUnderlines` draws underline bookmarks as vertical side strokes for vertical pages. Do not use horizontal bottom-line underline drawing for vertical text.

Step 1 uses `mutableString.replaceOccurrences` which preserves NSAttributedString attributes (unlike `setString` which destroys them). All replacements are length-preserving (1:1 UTF-16).

### Vertical Scroll Engine

Paged and scroll reading are separate engines inside `EPUBPageRenderer`:

| Mode | Pipeline |
| --- | --- |
| Paged | `CoreTextPageEngine` -> `UIPageViewController` -> `CoreTextPageView` |
| Scroll | `CoreTextScrollEngine` -> `UITableView` -> `CoreTextChunkCell` |

Guardrails:

- `ReaderView.body` routing order is sensitive. `else if settings.scrollMode { scrollBody }` must stay before the paged-engine-ready branch, or EPUB readiness prevents scroll mode from rendering.
- When `useRenderableNodePipeline` is false, the paged engine can use the `resourceProvider:` path without a builder, but the scroll engine still needs an `AttributedStringBuilding`. Build `EPUBAttributedStringBuilder` for both branches in `EPUBPageRenderer.load`.
- EPUB full-page images use `result.imagePage`, not an attributed-string `CTRunDelegate`. Scroll mode must synthesize an `isImageOnly` chunk or cover chapters disappear.
- Inline images use `\u{FFFC}` plus `kCTRunDelegateAttributeName(ImageRunInfo)`. `CTFrameDraw` reserves space only; draw images after extracting run rects via `CoreTextChunkAttachmentExtractor`.
- The slicer height cap is about 2000 pt. Large covers can make `CTFramesetterSuggestFrameSizeWithConstraints` return `length=0`; retry with `.greatestFiniteMagnitude` and ensure `blockImageHeight()` can fit the image.
- Table updates race easily. `numberOfRowsInSection` should use the VC-owned `displayedCount`, not `engine.chunks.count`; bump it synchronously inside `beginUpdates`/`endUpdates`.
- Start scroll layout from the UIKit VC `viewDidLayoutSubviews` width. SwiftUI preference size can still be `(0, 0)` when `.task(id:)` runs.
- Scroll progress changes must update the paged engine through `pagedEngine.pageIndex(forSpine:charOffset:)`, or switching back to paged mode jumps to an old page.
- Clearing selection must also hide `UIMenuController`, or the copy menu can stay visible after highlight clears.
