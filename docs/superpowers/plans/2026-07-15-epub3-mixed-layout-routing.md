# EPUB 3 Mixed-Layout Spine Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render each spine item with its effective EPUB layout mode when one publication mixes reflowable and pre-paginated content.

**Architecture:** Preserve the existing CoreText and fixed-layout engines as focused children. Add a `MixedLayoutPageEngine` that owns the reader-facing global page map: every fixed spine contributes exactly one slot, while every reflowable spine contributes its CoreText page slots. Small package-internal vending methods let the composite request a child controller with the composite global page number, and `EPUBPageRenderer` selects the composite only when item-level overrides actually mix layouts.

**Tech Stack:** Swift 6, CoreText, UIKit page controllers, Swift Testing, `PublicationSession`, `EPUBTestFixtures`

---

### Task 1: Add the mixed-rendition fixture and red routing contract

**Files:**
- Create: `Tests/iOS/yuedu appTests/EPUBTestFixtures+MixedLayout.swift`
- Create: `Tests/iOS/yuedu appTests/EPUBMixedLayoutRoutingTests.swift`

- [ ] **Step 1: Add a three-spine mixed-layout EPUB**

```swift
import Foundation

extension EPUBTestFixtures {
    @MainActor
    static func mixedLayout() -> Sample {
        Sample(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "EPUB/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">urn:yuedu:mixed-layout</dc:identifier>
                <dc:title>Mixed Layout</dc:title><dc:language>en</dc:language>
                <meta property="rendition:layout">reflowable</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="before" href="before.xhtml" media-type="application/xhtml+xml"/>
                <item id="painting" href="painting.xhtml" media-type="application/xhtml+xml"/>
                <item id="after" href="after.xhtml" media-type="application/xhtml+xml"/>
                <item id="image" href="painting.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine>
                <itemref idref="before"/>
                <itemref idref="painting" properties="rendition:layout-pre-paginated"/>
                <itemref idref="after"/>
              </spine>
            </package>
            """.utf8),
            "EPUB/nav.xhtml": Data(xhtml(
                title: "Contents",
                body: #"<nav epub:type="toc"><ol><li><a href="before.xhtml">Before</a></li><li><a href="painting.xhtml">Painting</a></li><li><a href="after.xhtml">After</a></li></ol></nav>"#
            ).utf8),
            "EPUB/before.xhtml": Data(xhtml(
                title: "Before",
                body: "<h1>Before</h1><p>Reflowable prose before the painting.</p>"
            ).utf8),
            "EPUB/painting.xhtml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Painting</title><meta name="viewport" content="width=1200,height=800"/></head>
              <body style="margin:0"><img src="painting.jpg" alt="A fixture painting" style="width:100%;height:100%"/></body>
            </html>
            """.utf8),
            "EPUB/after.xhtml": Data(xhtml(
                title: "After",
                body: "<h1>After</h1><p>Reflowable prose after the painting.</p>"
            ).utf8),
            "EPUB/painting.jpg": makeJPEG(width: 1200, height: 800),
        ])
    }
}
```

- [ ] **Step 2: Write the effective-layout and page-controller assertions**

```swift
import Foundation
import Testing
import UIKit
@testable import yuedu_app

struct EPUBMixedLayoutRoutingTests {
    @Test @MainActor
    func itemOverrideUsesFixedControllerBetweenReflowableSpines() async throws {
        let sample = EPUBTestFixtures.mixedLayout()
        let url = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: url)

        #expect(session.layoutMode == .reflowable)
        #expect(session.chapters.map(\.layoutModeOverride) == [nil, .prePaginated, nil])

        let renderer = EPUBPageRenderer()
        renderer.load(
            publicationSession: session,
            bookIdentifier: "mixed-layout-fixture",
            renderSize: CGSize(width: 390, height: 700),
            settings: EPUBTestFixtures.renderSettings()
        )
        for _ in 0..<400 {
            if renderer.isCoreTextReady { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(renderer.isCoreTextReady)
        let engine = try #require(renderer.engine)

        let before = engine.pageViewController(for: .chapterStart(0))
        let painting = engine.pageViewController(for: .chapterStart(1))
        let after = engine.pageViewController(for: .chapterStart(2))

        #expect(before is CoreTextPageViewController)
        #expect(painting is FixedLayoutPageViewController)
        #expect(after is CoreTextPageViewController)

        let fixedGlobalPage = try #require(engine.pageIndex(for: .chapterStart(1)))
        #expect(engine.readingPosition(forPage: fixedGlobalPage)?.spineIndex == 1)
        let fixedLocal = engine.localPosition(for: fixedGlobalPage)
        #expect(fixedLocal.spineIndex == 1)
        #expect(fixedLocal.localPage == 0)
    }
}
```

- [ ] **Step 3: Run the focused test and verify RED**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/EPUBMixedLayoutRoutingTests' \
  -parallel-testing-enabled NO
```

Expected: FAIL because the painting controller is a CoreText controller (or a
CoreText placeholder). Do not relax the assertion to accept the publication-
level reflowable engine.

### Task 2: Expose child-controller vending with a caller-owned global index

**Files:**
- Modify: `Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/FixedLayoutPageEngine.swift`

- [ ] **Step 1: Add a package-internal CoreText chapter-page vendor**

Add this method next to `pageViewController(at:)`. It must use the same
configured and placeholder controllers as the existing method, but it receives
the composite global page explicitly.

```swift
func pageViewController(
    spineIndex: Int,
    localPage: Int,
    globalPage: Int
) -> UIViewController {
    guard (0..<chapterCount).contains(spineIndex) else {
        return pageViewController(at: 0)
    }
    guard let layout = _layouts[spineIndex],
          layout.pageRanges.indices.contains(localPage) else {
        let position = CoreTextReadingPosition.chapterStart(spineIndex)
        let placeholder = PlaceholderPageViewController(
            chapterTitle: chapterTitle(at: spineIndex),
            globalPage: globalPage,
            readingPosition: position,
            themeBackgroundColor: themeBackgroundColor,
            themeTextColor: themeTextColor
        )
        Task { [weak self] in
            await self?.preloadChapter(at: spineIndex)
            self?.onChapterReady?(spineIndex)
        }
        return placeholder
    }
    return configuredPageViewController(
        layout: layout,
        spineIndex: spineIndex,
        localPage: localPage,
        globalPage: globalPage
    )
}
```

- [ ] **Step 2: Add a package-internal fixed-spine vendor**

Refactor the existing fixed controller cache to use the spine index as its key,
then add the explicit global page method:

```swift
func pageViewController(spineIndex: Int, globalPage: Int) -> UIViewController {
    let clampedSpine = max(0, min(spineIndex, totalPages - 1))
    if let cached = pageVCs[clampedSpine],
       cached.globalPageIndex == globalPage {
        return cached
    }
    let controller = FixedLayoutPageViewController()
    controller.configure(globalPage: globalPage)
    pageVCs[clampedSpine] = controller
    loadPage(controller, spineIndex: clampedSpine)
    return controller
}
```

Extract the current asynchronous viewport/HTML/base-URL block from
`pageViewController(at:)` into this exact helper, then make both public protocol
vending and the new composite vendor call it:

```swift
private func loadPage(
    _ controller: FixedLayoutPageViewController,
    spineIndex: Int
) {
    Task { @MainActor [weak self, weak controller] in
        guard let self, let controller else { return }
        let pageSize = await viewportResolver.viewport(
            for: spineIndex,
            resourceProvider: resourceProvider
        )
        let html = (try? await resourceProvider.chapterHTML(at: spineIndex)) ?? ""
        let baseURL = session.resourceURL(for: session.chapters[spineIndex].href)
            .deletingLastPathComponent()
        controller.load(
            html: html,
            baseURL: baseURL,
            pageSize: pageSize,
            availableSize: renderSize
        )
    }
}
```

- [ ] **Step 3: Run existing engine tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderEngineContractTests' \
  -only-testing:'yuedu appTests/CoreTextCFIProgressTests' \
  -parallel-testing-enabled NO
```

Expected: both existing engine suites PASS.

### Task 3: Add the composite page map

**Files:**
- Create: `Modules/Core/ReaderCore/CoreText/MixedLayoutPageEngine.swift`
- Test: `Tests/iOS/yuedu appTests/EPUBMixedLayoutRoutingTests.swift`

- [ ] **Step 1: Define the effective-layout and slot model**

```swift
import UIKit

@MainActor
final class MixedLayoutPageEngine: PageRenderingProvider {
    enum Slot: Equatable {
        case reflowable(spineIndex: Int, localPage: Int, charOffset: Int)
        case fixed(spineIndex: Int)

        var spineIndex: Int {
            switch self {
            case .reflowable(let spineIndex, _, _), .fixed(let spineIndex):
                return spineIndex
            }
        }
    }

    private let session: PublicationSession
    private let reflowEngine: CoreTextPageEngine
    private let fixedEngine: FixedLayoutPageEngine
    private var slots: [Slot] = []
    private(set) var currentPage: Int = 0
    var totalPages: Int { slots.count }
    var layouts: [Int: CoreTextPaginator.ChapterLayout] {
        reflowEngine.layouts.filter {
            effectiveLayout(at: $0.key) == .reflowable
        }
    }
    var renderSize: CGSize { reflowEngine.renderSize }
    var offsetStore: CharOffsetStore { reflowEngine.offsetStore }
    var onChapterReady: ((Int?) -> Void)?
    var onNavigateToPage: ((Int) -> Void)?

    init(
        session: PublicationSession,
        reflowEngine: CoreTextPageEngine,
        fixedEngine: FixedLayoutPageEngine
    ) {
        self.session = session
        self.reflowEngine = reflowEngine
        self.fixedEngine = fixedEngine
        rebuildSlots()
        reflowEngine.onChapterReady = { [weak self] spineIndex in
            guard let self else { return }
            rebuildSlots()
            onChapterReady?(spineIndex)
        }
        fixedEngine.onChapterReady = { [weak self] spineIndex in
            guard let self else { return }
            rebuildSlots()
            onChapterReady?(spineIndex)
        }
    }

    private func effectiveLayout(at spineIndex: Int) -> EPUBLayoutMode {
        session.chapters[spineIndex].layoutModeOverride ?? session.layoutMode
    }
}
```

- [ ] **Step 2: Build one reader-facing global sequence**

Add `rebuildSlots()` with these exact invariants:

```swift
private func rebuildSlots() {
    slots = session.chapters.flatMap { chapter -> [Slot] in
        if effectiveLayout(at: chapter.index) == .prePaginated {
            return [.fixed(spineIndex: chapter.index)]
        }
        guard let layout = reflowEngine.layouts[chapter.index],
              layout.pageRanges.isEmpty == false else {
            return [.reflowable(
                spineIndex: chapter.index,
                localPage: 0,
                charOffset: 0
            )]
        }
        return layout.pageRanges.enumerated().map { localPage, range in
            .reflowable(
                spineIndex: chapter.index,
                localPage: localPage,
                charOffset: range.location
            )
        }
    }
}
```

On `start`, await both children and rebuild slots:

```swift
func start(renderSize: CGSize, bookId: String) async {
    await reflowEngine.start(renderSize: renderSize, bookId: bookId)
    await fixedEngine.start(renderSize: renderSize, bookId: bookId)
    rebuildSlots()
    onChapterReady?(nil)
}
```

On preload/invalidate, delegate by effective layout and rebuild before
notifying the reader.

- [ ] **Step 3: Implement every `PageRenderingProvider` mapping from slots**

Use the following contract; no method may delegate a composite global page
directly to a child global page:

| Contract | Required mapping |
| --- | --- |
| `totalPages` | `slots.count` |
| `currentPage` | composite index most recently requested by `pageViewController(at:)` |
| `pageIndex(for:)` | fixed: its sole slot; reflowable: slot whose local page contains the char offset |
| `estimatedGlobalPage(for:)` | exact result, otherwise first slot for the requested spine |
| `readingPosition(forPage:)` / `charOffset(forPage:)` | derive from the selected slot |
| `localPosition(for:)` | slot spine plus fixed `0` or stored reflow local page |
| `lastPageIndex(ofChapter:)` | last slot whose spine matches |
| `pageViewController(at:)` | call the child explicit-global vendor from Task 2 |
| `resolveInternalLink` | resolve the target spine with `session.chapterIndex(for:)`, then map its fragment/offset through the reflow child |
| theme/annotations | forward to both children; fixed no-op behavior remains valid |
| snapshots | request from the child using spine/local values, never composite index as child index |

The controller switch is:

```swift
func pageViewController(at index: Int) -> UIViewController {
    guard slots.isEmpty == false else { return reflowEngine.pageViewController(at: 0) }
    let globalPage = max(0, min(index, slots.count - 1))
    currentPage = globalPage
    switch slots[globalPage] {
    case .fixed(let spineIndex):
        return fixedEngine.pageViewController(
            spineIndex: spineIndex,
            globalPage: globalPage
        )
    case .reflowable(let spineIndex, let localPage, _):
        return reflowEngine.pageViewController(
            spineIndex: spineIndex,
            localPage: localPage,
            globalPage: globalPage
        )
    }
}
```

`offsetStore`, `layouts`, `renderSize`, and reflowable text/progress metrics
come from the reflow child, but page-count/progression calculations use the
composite slots. Keep fixed items at `charOffset == 0`.

- [ ] **Step 4: Compile and rerun the focused test**

Run the Task 1 test command.

Expected at this intermediate point: the new engine compiles, but the test is
still RED because `EPUBPageRenderer` has not selected it.

### Task 4: Select the composite only for genuinely mixed publications

**Files:**
- Modify: `Modules/Core/ReaderCore/EPUBPageRenderer.swift`
- Test: `Tests/iOS/yuedu appTests/EPUBMixedLayoutRoutingTests.swift`

- [ ] **Step 1: Detect effective mixed layout once during load**

```swift
let effectiveLayouts = session.chapters.map {
    $0.layoutModeOverride ?? session.layoutMode
}
let isMixedLayout = effectiveLayouts.contains(.reflowable)
    && effectiveLayouts.contains(.prePaginated)
```

Keep the existing all-fixed `FixedLayoutPageEngine` branch. In the reflowable
branch, construct the existing builder and CoreText engine first. When
`isMixedLayout` is true, also construct a fixed engine and install:

```swift
let selectedEngine: any PageRenderingProvider
if isMixedLayout {
    selectedEngine = MixedLayoutPageEngine(
        session: session,
        reflowEngine: newEngine,
        fixedEngine: FixedLayoutPageEngine(
            session: session,
            renderSize: effectiveSize
        )
    )
    scrollEngine = nil
} else {
    selectedEngine = newEngine
    scrollEngine = CoreTextScrollEngine(
        builder: builder,
        renderSettings: settings
    )
}
engine = selectedEngine
```

Start `selectedEngine`, not `newEngine`, in the existing task and set
`isCoreTextReady` only after it returns. Continuous scroll intentionally falls
back to the paged composite for mixed-layout publications; it must not omit the
fixed spine item.

- [ ] **Step 2: Run the focused test and verify GREEN**

Run the Task 1 command again.

Expected: the controllers are CoreText, fixed, CoreText in spine order; the
fixed global page maps back to spine 1/local page 0.

- [ ] **Step 3: Add boundary assertions and rerun**

Extend the same test with:

```swift
let beforeLast = try #require(engine.lastPageIndex(ofChapter: 0))
let fixedPage = try #require(engine.pageIndex(for: .chapterStart(1)))
let afterFirst = try #require(engine.pageIndex(for: .chapterStart(2)))
#expect(fixedPage == beforeLast + 1)
#expect(afterFirst == fixedPage + 1)
let fixedOffset = engine.charOffset(forPage: fixedPage)
#expect(fixedOffset.spineIndex == 1)
#expect(fixedOffset.charOffset == 0)
```

Run the focused test again. Expected: PASS with no skipped assertions.

- [ ] **Step 4: Commit the regression and routing engine**

```bash
git add \
  Modules/Core/ReaderCore/EPUBPageRenderer.swift \
  Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift \
  Modules/Core/ReaderCore/CoreText/FixedLayoutPageEngine.swift \
  Modules/Core/ReaderCore/CoreText/MixedLayoutPageEngine.swift \
  'Tests/iOS/yuedu appTests/EPUBTestFixtures+MixedLayout.swift' \
  'Tests/iOS/yuedu appTests/EPUBMixedLayoutRoutingTests.swift'
git commit -m "fix: route mixed-layout EPUB spine items"
```

### Task 5: Verify the official mixed sample and record evidence

**Files:**
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-003/README.md`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-003/before.png`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-003/after.png`
- Modify: `docs/build-week/epub3/compatibility-matrix.md`

- [ ] **Step 1: Run the official production corpus**

Run the current-branch corpus command in `docs/build-week/epub3/README.md`.

Expected: all 42 sample cases run with zero skips, and
`the-voyage-of-life` no longer reports that its fixed target was routed through
the general CoreText engine. Unrelated baseline failures remain visible.

- [ ] **Step 2: Capture the fixed painting before and after**

Use `the-voyage-of-life` on iPhone 17 Pro Max / iOS 27.0 / light theme / paged
mode. Navigate from the preceding reflowable prose into
`EPUB/xhtml/1b-childhood-painting.xhtml`. Baseline shows the reflow/blank
presentation; after shows the fitted fixed painting. Keep the same orientation,
viewport, page, and crop.

- [ ] **Step 3: Write evidence metadata from durable values**

In `README.md`, use the exact field labels from the evidence contract. Set:

- Sample/checkpoint to `the-voyage-of-life / 1b-childhood-painting.xhtml`.
- Sample checksum to `e38ed606ff604e638f737efaf66e0fd0b2997c3eab7432bcba9a00a81a925cf3`.
- Baseline commit to `dd62d8047aaef47bd93dee4c6c4af277ac628f26`.
- After commit to the 40-character output of `git rev-parse HEAD` for Task 4.
- Fixture to `EPUBTestFixtures+MixedLayout.swift` / `mixedLayout()`.
- Test command to the focused Task 1 `xcodebuild` command.
- Device/iOS/settings to iPhone 17 Pro Max / iOS 27.0 / light, paged, defaults.
- Expected behavior to the fixed painting occupying one fitted page between
  the two reflowable spines.
- Observed behavior to the baseline CoreText route and after fixed controller.
- Official content visible to `yes` and License attribution to the exact
  manifest attribution/license text.

- [ ] **Step 4: Update, validate, and commit the evidence**

Update only the `the-voyage-of-life` row with `BW-EPUB3-003`, the focused test,
evidence directory, and fix SHA. Do not mark the separate textual-overlay
sample or scripting as fixed.

```bash
python3 scripts/epub3_samples.py matrix-check
python3 -m unittest discover -s Tests/Tools -p 'test_epub3_samples.py' -v
git diff --check
git add docs/build-week/epub3/compatibility-matrix.md \
  docs/build-week/epub3/evidence/BW-EPUB3-003
git commit -m "docs: record mixed-layout EPUB evidence"
```
