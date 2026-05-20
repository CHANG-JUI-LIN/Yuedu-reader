---
layout: post
title: "From WebView to CoreText: Building a Native EPUB Reader for iOS"
description: "How CJK vertical writing pushed Yuedu Reader away from WebView and toward a custom CoreText rendering engine."
date: 2026-05-20
tags:
  - ios
  - swift
  - epub
  - coretext
  - cjk
  - typography
---

# From WebView to CoreText: Building a Native EPUB Reader for iOS

How CJK vertical writing pushed my reader away from WebView and toward a custom rendering engine.

![Yuedu Reader CJK vertical reading demo](https://raw.githubusercontent.com/CHANG-JUI-LIN/Yuedu-reader/main/docs/demo/cjk-vertical-toc.gif)

This post covers why Yuedu Reader moved from basic reading workflows to a CoreText-based EPUB rendering path, what Readium still helped with, and why CJK vertical writing affects much more than glyph drawing.

## Contents

- [Why WebView was not enough](#why-webview-was-not-enough)
- [Readium helped, but it was not the end](#readium-helped-but-it-was-not-the-end)
- [The CoreText pipeline](#the-coretext-pipeline)
- [Stable position beats page number](#stable-position-beats-page-number)
- [CJK vertical writing changed the renderer](#cjk-vertical-writing-changed-the-renderer)
- [The table of contents had to become directional too](#the-table-of-contents-had-to-become-directional-too)
- [Pagination is a cache problem too](#pagination-is-a-cache-problem-too)
- [What I would not underestimate again](#what-i-would-not-underestimate-again)
- [Where Yuedu is now](#where-yuedu-is-now)

When I started building Yuedu Reader, I was not trying to build an EPUB rendering engine.

The original goal was a native iOS reader for web novels, TXT files, and long-form reading workflows I personally wanted. I cared about CJK reading from the beginning, but mostly in the sense of making plain text and online fiction comfortable to read.

EPUB came later. At first, I treated it as another import format: parse the package, load XHTML chapters, apply CSS, and render the text.

After I got basic EPUB opening working, I came across a vertical Traditional Chinese EPUB edition of Dream of the Red Chamber with dense inline commentary. That book changed how I thought about EPUB.

Before that, I treated EPUB mostly as a container: XHTML, CSS, images, metadata, and chapters. After seeing that book, I understood why people still care about EPUB as a reading format. It can preserve typography, structure, annotations, navigation, and the feeling of a designed book.

That was when CJK vertical writing stopped being a checkbox and became one of the core requirements of the reader.

## Why WebView was not enough

The first EPUB prototype used `WKWebView`, because EPUB content is mostly XHTML, CSS, images, links, and metadata. A web view looked like the obvious renderer.

`WKWebView` is a reasonable choice for many EPUB readers. It already understands HTML, CSS, links, images, scrolling, text selection, and layout. If the product is mostly a web-document viewer, WebView is hard to beat.

Yuedu Reader needed a different kind of control:

- page-based reading instead of only scrolling
- custom native page-turn interaction
- stable reading position based on content coordinates
- highlight, annotation, and TTS ranges tied to rendered text
- CJK vertical writing
- reader-specific image, link, and table-of-contents behavior

Some of these are possible with WebView. Combining all of them made the reader feel like a stack of workarounds.

A reader is not just a web page viewer. Page numbers need to be stable enough for navigation. Highlights need precise text ranges. TTS needs to follow the rendered text. Page turns need to feel native. CJK vertical writing needs punctuation handling, mixed Latin handling, inline images, annotation spans, and right-to-left reading flow.

The first real stress test was not a fancy EPUB feature. It was CJK vertical writing: right-to-left page flow, vertical punctuation, mixed Latin text, inline commentary, and a table of contents that suddenly felt wrong when it stayed horizontal.

The hardest WebView bugs were not compile errors. They were runtime reader bugs: blank pages after a chapter switch, tap-to-turn failing after repeated navigation, repeated pages, slow snapshot generation, and page offsets based on stale WebView geometry.

In the early WebView version, one coordinator slowly became the reader engine: page-turn state, `WKWebView` pooling, chapter loading, table-of-contents scanning, progress restore, snapshot rendering, and WebKit callbacks all lived too close together.

The WebView version taught me what the app needed. It also made clear that the main reading engine needed to own layout.

## Readium helped, but it was not the end

Readium helped me understand EPUB structure more seriously. It gave me a better model for publications, spine items, resources, navigation, and metadata. It also made the app less dependent on ad hoc EPUB parsing.

At one point I made Readium the only EPUB open path. That was the right move. A single publication-opening path gave the reader a clearer contract: open the publication, understand the spine and resources, then hand the content to the renderer.

But my goal was not only to open EPUB files. I wanted the main reader to feel fully native on iOS:

- CoreText pagination
- custom page transitions
- reader-owned tap zones
- precise text selection and highlight geometry
- CJK-aware typography and vertical reading UI
- stable restore points across layout changes

So Yuedu ended up using EPUB concepts from the ecosystem while building the primary reflowable rendering path itself.

Today the split is deliberate:

- Reflowable EPUB goes through Yuedu's CoreText reader.
- Fixed-layout EPUB can still use a WebView-based renderer, because fixed-layout content is closer to a web page or positioned canvas.
- Readium remains important for EPUB opening and publication structure.

That boundary is important. The point was never "WebView is bad." The point was that the main reading surface needed a native layout engine.

## The CoreText pipeline

The CoreText path in Yuedu is roughly:

```text
EPUB spine/resources
→ XHTML/CSS
→ styled tree
→ attributed text / renderable nodes
→ CTFramesetter pagination
→ CoreText page view
```

After that, the reader attaches app behavior: taps, selection, highlights, images, links, TTS progress, and page-turn state.

One recurring lesson was that parsing support is not enough. If a CSS property affects layout, it has to survive the whole path from EPUB source to attributed text, pagination, drawing, hit testing, and cache invalidation. Otherwise a feature works in one place and quietly fails somewhere else.

For example, links are not only visual style. In the RenderableNode path, an EPUB `<a>` becomes a reader-specific attribute that later drives hit testing:

```swift
case .anchor(let href, let children):
    var childCtx = ctx
    childCtx.linkHref = href
    return await renderInlineChildren(children, ctx: childCtx)

var baseAttributes: [NSAttributedString.Key: Any] {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: paragraphStyle
    ]

    if let href = linkHref {
        attrs[HTMLAttributedStringBuilder.internalLinkAttribute] = href
        attrs[.foregroundColor] = UIColor.systemBlue
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attrs[HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute] =
            UIColor.systemBlue
    }

    return attrs
}
```

The important part is not only converting CSS into visual attributes. Reader-specific metadata, such as links, image sources, anchors, and writing mode, has to survive into pagination and hit testing.

## Stable position beats page number

One of the biggest design shifts was moving away from page number as identity.

Page numbers are output, not source truth. They change when the font size changes, when margins change, when an image finally loads, when CSS changes, or when a chapter is lazily loaded.

Yuedu stores reading position as content coordinates, then resolves it through the current layout:

```swift
struct CoreTextReadingPosition: Codable, Equatable {
    let spineIndex: Int
    let charOffset: Int

    static func chapterStart(_ spineIndex: Int) -> Self {
        Self(spineIndex: spineIndex, charOffset: 0)
    }

    static func chapterEnd(_ spineIndex: Int) -> Self {
        Self(spineIndex: spineIndex, charOffset: .max)
    }
}

enum CoreTextReadingPositionMapper {
    static func pageIndex(
        for position: CoreTextReadingPosition,
        layouts: [Int: CoreTextPaginator.ChapterLayout],
        spinePageOffsets: [Int]
    ) -> Int? {
        guard spinePageOffsets.indices.contains(position.spineIndex),
              let layout = layouts[position.spineIndex] else {
            return nil
        }

        let localPage = layout.pageIndex(
            for: clampedCharOffset(for: position, in: layout)
        )
        return spinePageOffsets[position.spineIndex] + localPage
    }

    static func clampedCharOffset(
        for position: CoreTextReadingPosition,
        in layout: CoreTextPaginator.ChapterLayout
    ) -> Int {
        let upperBound = max(layout.attributedString.length, 0)
        if position.charOffset == .max {
            return upperBound
        }
        return min(max(position.charOffset, 0), upperBound)
    }
}
```

The page index is derived after layout. It is not the durable state. That means the app can rebuild layout and then ask the mapper to resolve the nearest page for the same content position.

This matters for restoring progress, switching between paged and scroll modes, jumping from the table of contents, bookmarks, highlights, and TTS progress.

The UI can still show page numbers, but the reader state is not defined by them. The source of truth is "which spine item and which character offset."

## CJK vertical writing changed the renderer

CJK vertical writing was the feature that made the CoreText path unavoidable.

Horizontal Latin text is already complex. Vertical CJK text adds another set of rules:

- columns progress right to left
- punctuation needs vertical forms
- Latin words and numbers should often remain sideways as grouped runs
- inline images and annotation spans need custom geometry
- hit testing changes axis meaning
- selection rectangles are column-local
- reading direction must be handled carefully

CoreText supports vertical text, but not as a complete EPUB reader. You still have to build the surrounding engine.

In Yuedu, the vertical switch is split between frame creation and attributed-string preparation. The frame attributes only tell CoreText how columns should progress:

```swift
static func frameAttributes(for writingMode: ReaderWritingMode) -> [String: Any] {
    switch writingMode {
    case .horizontal:
        return [:]
    case .verticalRTL:
        return [
            kCTFrameProgressionAttributeName as String:
                Int(CTFrameProgression.rightToLeft.rawValue)
        ]
    }
}

let attributes = frameAttributes(for: writingMode)
let frameAttributes = attributes.isEmpty ? nil : attributes as CFDictionary

return CTFramesetterCreateFrame(
    framesetter,
    range,
    path,
    frameAttributes
)
```

That is not enough by itself. Before pagination, the paginator normalizes punctuation, applies font fallback, applies vertical forms globally, then removes vertical forms from non-CJK Latin and numeric runs so mixed English text can stay readable as sideways groups.

The coordinate system also changes. In horizontal text, `CTLineGetOffsetForStringIndex` feels like an x-axis measurement. In vertical-rl, that same value behaves like inline progress from the top of the column.

```text
horizontal:  x moves across the line
vertical-rl: offset moves down the column
```

The API names are still `ascent`, `descent`, and `offset`, but the mental model is different.

That affected much more than drawing:

- link hit testing
- selection handles
- underline annotation rectangles
- image tap targets
- table-of-contents behavior

The hard part was not only rendering vertical glyphs. It was making every reader interaction understand that the page had rotated conceptually, while keeping the app's existing page-turn behavior intact.

## The table of contents had to become directional too

Once vertical reading worked on the page, the table of contents started to feel wrong.

For a vertical CJK book, a normal left-to-right chapter list is functional but visually inconsistent. Yuedu added a vertical table of contents mode that follows the book's reading direction.

This became its own rendering problem:

- chapter titles can be long
- Latin tokens inside CJK titles need special handling
- page numbers should reflect actual CoreText page offsets, not just chapter indexes
- auto-scroll should not fight the user's position

This is where building a reader differs from building a document viewer. The UI around the book has to respect the same reading model as the page itself.

## Pagination is a cache problem too

CoreText pagination can be expensive. Yuedu caches chapter layouts, but the cache key has to include anything that can change layout. In the app, that key currently looks like this:

```swift
private struct CacheKey: Hashable {
    let spineIndex: Int
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat
    let marginH: CGFloat
    let marginV: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let letterSpacing: CGFloat
    let writingMode: ReaderWritingMode
    let contentFingerprint: Int
}
```

This sounds obvious, but it is one of the places where reader engines fail quietly. If any layout-affecting value is missing from this key, the bug does not look like a cache bug at first. It looks like wrong page counts, stale highlights, broken TOC page numbers, or a reader that ignores typography changes.

The same issue appears with page offsets. A table of contents can only show useful page numbers if the engine can resolve real chapter offsets after layout.

## What I would do the same

I would still start with WebView. It was the fastest way to understand EPUB content and prove that the app could open real books.

I would also still use Readium concepts instead of pretending EPUB is just a folder of HTML files. The spine, resources, navigation documents, metadata, and publication-level direction all matter.

And I would still move the main reflowable reader to CoreText once native pagination, text ranges, TTS synchronization, and CJK vertical writing became central to the product.

## What I would not underestimate again

I underestimated how much EPUB rendering is not text drawing.

The hard parts were the small contracts between systems:

- CSS parsing and CoreText paragraph styles
- publisher margins and app margins
- vertical text geometry and UIKit touch coordinates
- internal links and page navigation
- image metadata and image tap targets
- cache invalidation and reading progress
- table-of-contents entries and spine positions
- TTS playback and rendered ranges

Images are not just painted pixels. A reader should know what image was tapped, where it came from, what its alt text is, and whether it should open inside the app or navigate externally. Links are similar: it is not enough for an internal EPUB link to be tappable if users cannot discover it visually.

Each bug looked local at first. A clipped callout block looked like a drawing issue. A wrong margin looked like CSS. An invisible link looked like metadata. A vertical TOC issue looked like a SwiftUI layout problem. Most of them were really pipeline bugs: some piece of semantic information failed to travel from EPUB source to rendered page to interaction layer.

That is the main lesson from building a CoreText EPUB reader: **the renderer is not only the thing that draws glyphs. It is the system that preserves meaning across parsing, layout, drawing, and interaction.**

## Where Yuedu is now

Yuedu Reader now uses a native CoreText reader for the main EPUB/TXT reading experience. It supports paged and scroll modes, CJK vertical writing, vertical table of contents, highlights, bookmarks, TTS, image preview, internal links, publisher CSS, and a growing EPUB regression corpus.

It is still not a complete EPUB engine. EPUB compatibility is a long tail. Fixed-layout EPUB, complex CSS, SVG, media overlays, and publisher-specific edge cases can each become their own project.

But the architecture now matches the product I wanted to build: EPUB structure from the ecosystem, native iOS interaction, CoreText-owned pagination, stable content-coordinate reading position, and CJK typography as a first-class requirement.

That path took longer than embedding a web view. It also made the reader feel like an iOS reading app instead of a browser with page-turn gestures.

---

Yuedu Reader is open source here:

[github.com/CHANG-JUI-LIN/Yuedu-reader](https://github.com/CHANG-JUI-LIN/Yuedu-reader)
