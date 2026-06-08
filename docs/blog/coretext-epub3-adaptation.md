---
layout: post
title: "Adapting EPUB 3 Features to CoreText in Yuedu Reader"
description: "How Yuedu Reader routes fixed layout, media overlays, HTML5 media, CSS float, tables, and RTL/bidi EPUB behavior through a native CoreText reading engine."
date: 2026-06-08
tags:
  - ios
  - swift
  - epub3
  - coretext
  - reader
  - typography
---

# Adapting EPUB 3 Features to CoreText in Yuedu Reader

Yuedu Reader's main reading surface is not a WebView. It is a native SwiftUI shell around a CoreText pagination and interaction engine. That decision started with CJK vertical writing, stable pagination, text selection, highlights, and TTS synchronization. The harder test came later, when real EPUB 3 books started combining fixed layout, `nav.xhtml`, media overlays, HTML5 audio and video, CSS float, tables, RTL/bidi text, font styling, and box-model details in the same publication.

This post is a practical engineering note about connecting EPUB 3 semantics to a CoreText reader. It is not a guide to writing an EPUB engine from scratch. The more useful question is narrower: once you already have a native CoreText reader, how do EPUB 3 features survive parsing, intermediate representation, attributed strings, pagination, drawing, hit testing, playback, and regression tests?

## Contents

- [CoreText Is Not an HTML Renderer](#coretext-is-not-an-html-renderer)
- [Publication Metadata Becomes a Reader Contract](#publication-metadata-becomes-a-reader-contract)
- [Keep EPUB HTML Semantics Alive in an IR](#keep-epub-html-semantics-alive-in-an-ir)
- [Fixed Layout Does Not Belong in the Reflow Engine](#fixed-layout-does-not-belong-in-the-reflow-engine)
- [Media Overlays Are Playback Scripts](#media-overlays-are-playback-scripts)
- [HTML5 Media Needs Placeholders and Native Controls](#html5-media-needs-placeholders-and-native-controls)
- [CSS Float, Tables, and the Box Model](#css-float-tables-and-the-box-model)
- [RTL and Bidi Are Not the Same as Vertical Writing](#rtl-and-bidi-are-not-the-same-as-vertical-writing)
- [Regression Testing with Small EPUBs](#regression-testing-with-small-epubs)
- [What This Work Taught Me](#what-this-work-taught-me)

## CoreText Is Not an HTML Renderer

EPUB 3 content often looks like "XHTML plus CSS plus media." If you use a WebView, the browser already handles flow layout, media elements, links, selection, bidi, tables, float, and CSS cascade. Once the main renderer becomes CoreText, none of that exists by default.

So the boundary in Yuedu is not "CoreText replaces the browser." The boundary is more deliberate:

- Reflowable text reading uses CoreText because it needs native pagination, selection, highlights, TTS, vertical writing, and stable reading positions.
- Fixed-layout EPUB uses `FixedPageReader` because it is closer to positioned pages or visual canvases than to reflowable text.
- Readium and EPUB parsing still provide publication structure: spine items, resources, metadata, and navigation.
- The CoreText pipeline turns reflowable content into pages, scroll chunks, attachments, and interaction regions.

WebView is not the enemy. The mistake would be pretending every EPUB 3 feature is just paragraph text.

The recent commit history shows this direction clearly:

- `1b8e65d` added bookmarks/highlights list support, media overlays, landscape behavior, and tables.
- `1214fbb` moved fixed-layout EPUB and manga onto the shared `FixedPageReader`.
- `0484c49` added inline video, background soundtrack handling, CSS float text wrapping, and image fixes.
- `fb2b268` extended CSS float into the renderable IR and scroll path.
- `0fd39ed` added RTL/bidi support for Hebrew and Arabic EPUBs.

Those are not isolated features. Together, they move EPUB support from "the book opens" toward "the reader preserves the book's semantics and reading behavior."

## Publication Metadata Becomes a Reader Contract

Important EPUB 3 information is often not inside a single XHTML chapter. It lives in OPF metadata, spine items, manifest properties, and navigation resources. A CoreText renderer cannot wait until draw time to guess it.

Yuedu extracts reader-level contracts in `PublicationSession`:

- `EPUBLayoutMode`: reflowable or pre-paginated.
- `EPUBPageProgressionDirection`: LTR, RTL, or default.
- `EPUBWritingMode`: horizontal, vertical-rl, or unspecified.
- Fixed-layout viewport, spread side, orientation, and spread behavior.
- `media-overlay` links to SMIL resources.
- `nav.xhtml` and `toc.ncx` navigation entries.

That layer matters because the rest of the reader needs to know how the book should be read, not just what an XML attribute looked like.

For example, `page-progression-direction="rtl"` means right-to-left page progression. It does not automatically mean vertical writing. A Hebrew or Arabic EPUB can be horizontal RTL; a Traditional Chinese or Japanese EPUB may use vertical-rl because of metadata or CSS `writing-mode: vertical-rl`. This distinction became central when adding RTL/bidi support: not every RTL book is a CJK vertical book.

## Keep EPUB HTML Semantics Alive in an IR

CoreText eventually consumes attributed strings and frame paths, but EPUB 3 features cannot be flattened into text too early.

Yuedu has a `RenderableNode` path that looks roughly like this:

```text
XHTML + CSS
-> styled AST
-> RenderableNode
-> NodeAttributedStringRenderer
-> NSAttributedString + reader attributes
-> CoreTextPaginator / CoreTextScrollEngine
```

The IR keeps more than text:

- `anchor` preserves link targets.
- `ruby` preserves ruby annotations.
- `image` preserves `src`, `alt`, style, and inline SVG content.
- `table` preserves a table model.
- `media` preserves EPUB audio/video attachments.
- `pageBreak` preserves forced EPUB page breaks.
- `RenderStyle` preserves layout-affecting properties such as font, direction, margin, padding, border, float, background, width, and height.

That lets the renderer split the work:

1. Text-like content becomes attributed runs that `CTFramesetter` can paginate.
2. Content CoreText does not naturally understand becomes attachments, placeholders, rasterized blocks, or separately drawn layers.

If HTML is parsed straight into plain text, most EPUB 3 behavior is already gone before pagination begins.

## Fixed Layout Does Not Belong in the Reflow Engine

EPUB 3 fixed layout is one of the easiest ways to break a CoreText reader. Fixed layout is about pages: viewport, page spread, orientation, left/right/center page placement. That is a different problem from reflowable text.

Yuedu routes this through `FixedPageReader`:

- `FixedLayoutEPUBPageProvider` supplies fixed-layout pages.
- `FixedPageReaderConfiguration` defines shared fixed-layout and manga reading modes.
- `FixedPagePagedViewController` and the webtoon path handle zooming, paging, and continuous reading.
- `FixedLayoutSpreadPairingBuilder` pairs left and right pages based on LTR/RTL and spread side.

The point is not to force everything through CoreText. Fixed-layout EPUB needs the reader to preserve viewport and page relationships, especially on iPad landscape, spread mode, and RTL spines.

Commit `1214fbb` moved fixed-layout EPUB and manga onto the shared FixedPageReader. That was not a shortcut. It put the problem in the correct reader surface.

## Media Overlays Are Playback Scripts

EPUB media overlays are not just "an audio file in the book." SMIL ties text fragments to audio clips. The reader has to know:

- which chapter has an overlay,
- which text target each fragment maps to,
- the begin and end time of each audio clip,
- which fragment should be highlighted during playback,
- and how playback should stop or switch when the user changes chapter or page.

Yuedu models overlays and fragments in `EPUBMediaOverlay.swift`, parses spine item `media-overlay` references in `PublicationSession`, then connects them to `EPUBMediaOverlayPlaybackCoordinator` and `EPUBMediaOverlayPlayerView`.

CoreText is not responsible for audio playback itself. Its job is to provide a text world that can be addressed. A media overlay fragment must become a highlightable target inside the CoreText page. This is the same family of problems as TTS, highlights, and bookmarks: interaction should return to a stable `(spineIndex, charOffset)` or anchor/fragment contract, not to "the current page number."

The media overlay work in `1b8e65d` also touched highlights, bookmarks, landscape behavior, and tables because once overlay playback enters the reader, visible pages, text locations, selection, and control surfaces all become part of the feature.

## HTML5 Media Needs Placeholders and Native Controls

EPUB 3 allows audio and video. A WebView can render media elements directly. CoreText cannot.

Yuedu turns media elements into reader attachments:

- Inline audio/video becomes `RenderableNode.media` or an attributed placeholder in the text flow.
- Pagination reserves geometry for the placeholder.
- `CoreTextPageView` draws the placeholder or installs a tappable media layer.
- `EPUBMediaPlayerView` provides native playback controls.
- Controls-less background audio is handled by `EPUBBackgroundAudioCoordinator` instead of drawing fake controls on the page.

The important distinction is that media visibility and media playback behavior are not the same thing. A video with controls should have visible native interaction. A background soundtrack may be managed invisibly. A broken video frame must not explode page layout.

That is why commits `0484c49` and `c674d57` handled inline video, background soundtrack, media playback, controls-less audio, and CoreText placeholder geometry together.

## CSS Float, Tables, and the Box Model

CoreText's natural model is "lay text inside a path." CSS float says "this image occupies a region and following text wraps around it." Those models can work together, but only if the reader converts float into path geometry.

Yuedu handles float like this:

1. The HTML builder sees `float: left/right` on an image and emits a zero-width marker.
2. The marker carries a `FloatPlaceholder` with side, resolved drawing size, and margins.
3. The paginator reads that marker and cuts a notch out of the CoreText frame path.
4. Following text is laid out beside the notch.
5. The image is drawn separately as an attachment inside the notch.

Float must exist in both paged and scroll paths. If paged mode handles float but scroll chunk slicing does not, text and images overlap or disappear when the same chapter is read in scroll mode. Commit `fb2b268` extended CSS float into the IR and scroll path to close that gap.

Tables require a different tradeoff. CoreText can lay out text, but it is not a table layout engine. Yuedu keeps table structure as `HTMLTableModel`, then rasterizes it into a block that can be inserted into the reading flow. It is not full CSS table support, but it is practical for a reader: row, cell, header, and caption semantics survive long enough to avoid turning a table into unreadable inline text.

The box model follows the same rule. Borders, backgrounds, padding, margins, `hr` width/alignment, font weight, italic styling, and whitespace collapsing cannot live only in the CSS parser. They must pass through the whole pipeline:

```text
CSSPropertyApplier
-> ResolvedStyle / RenderStyle
-> NodeAttributedStringRenderer
-> CoreTextPaginator / line drawer / block renderer
-> tests
```

Commits such as `16e6d59`, `1c21ebc`, and `c3c5f52` may look like small CSS fixes, but the real work was preserving CSS semantics through the CoreText pipeline.

## RTL and Bidi Are Not the Same as Vertical Writing

My first RTL requirement came from CJK vertical writing: vertical books progress right to left, and columns progress right to left. Hebrew and Arabic EPUBs exposed another case: horizontal text can also be RTL.

These are three different concepts:

- writing mode: horizontal or vertical-rl,
- page progression: LTR or RTL page turns,
- paragraph direction / bidi: inline text direction and Unicode bidi behavior.

The CoreText path has to handle them separately. `page-progression-direction="rtl"` should not automatically enable vertical layout. `direction: rtl` and `unicode-bidi` should flow into paragraph or render style. CJK vertical writing should still use `ReaderWritingMode.verticalRTL`.

Commit `0fd39ed` fixed this layering for Hebrew and Arabic EPUBs. It touched metadata handling in `PublicationSession`, `direction`/bidi style application in `CSSPropertyApplier`, style propagation through `HTMLAttributedStringBuilder` and `NodeAttributedStringRenderer`, and EPUB fixtures in `EPUBRenderingTests`.

For a reader, RTL is not one switch. It is a contract that affects parsing, layout, page turns, gestures, and tests.

## Regression Testing with Small EPUBs

EPUB bugs hide easily inside real books. A single production EPUB can include CSS, images, fonts, chapters, TOC files, media, and publisher-specific markup. Without a small reproduction, debugging turns into screenshot archaeology.

Yuedu now keeps small EPUB regression fixtures for targeted behavior:

- `nav-xhtml-basic.epub` tests EPUB 3 `nav.xhtml`.
- `toc-ncx-basic.epub` tests EPUB 2 `toc.ncx`.
- `hr-divider-width-alignment-margins.epub` tests HR width, alignment, and margins.
- `paragraph-border-background.epub` tests paragraph border, background, padding, and margins.
- `block-image-before-paragraph.epub` tests that an image-only block does not overlap the next paragraph.
- `centered-percent-image.epub` tests percentage image sizing.

The tests try to verify reader contracts, not only parser success:

- publication metadata becomes the correct writing mode and page progression,
- TOC fragments are preserved,
- fixed-layout spread pairs match RTL/LTR expectations,
- CoreText pages and chunks keep attachments,
- media placeholders have stable frames,
- float markers wrap text,
- scroll and paged paths remain consistent.

That is why the recent EPUB commits usually include `EPUBRenderingTests`, `ReaderPresentationContractTests`, or `CoreTextScrollTests`. CoreText reader bugs are often not single API failures. They are usually places where a semantic value disappeared somewhere in the pipeline.

## What This Work Taught Me

First, CoreText is a good foundation for a native reader, but it does not understand EPUB for you. CoreText lays out and draws text. The reader has to preserve EPUB semantics.

Second, do not flatten content into attributed strings too early. Attributed strings are powerful, but they are not a full document model. Tables, media, float, fixed layout, page breaks, and anchor targets need to remain alive in an IR or reader contract for a few more stages.

Third, every layout-affecting input belongs in the cache key. Font, line height, writing mode, image size, background, float notch, and content insets can all change page count or geometry. Missing one eventually becomes "the page count is sometimes wrong" or "changing settings jumps to the wrong page."

Fourth, EPUB 3 is not one feature. It is a set of interacting semantics. Media overlays affect text addressing. Fixed layout affects spread and orientation. RTL affects gestures and page progression. CSS float affects CoreText path geometry. Tables affect attachments and accessibility.

Fifth, small EPUB fixtures are worth the time. Real books reveal problems. Small fixtures keep the same problems from coming back.

If I were rebuilding this now, I would keep the same split: reflowable reading through CoreText, fixed-layout reading through `FixedPageReader`, publication metadata converted into reader contracts, and an IR that carries EPUB semantics far enough for the renderer to do the right thing.

This path is harder than using a WebView as the whole reader, but it gives a native reader the control it needs: stable positions, predictable pagination, CJK and RTL typography, native interaction, TTS/media-overlay synchronization, and reading behavior that can be locked down with tests.
