# EPUB 3 TOC Dismissal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every EPUB TOC selection dismiss its sheet before starting potentially expensive chapter navigation.

**Architecture:** Add one main-actor selection action in `ReaderTOCViews.swift` that performs the binding dismissal synchronously and schedules navigation on the next main-actor turn. Route both horizontal and vertical TOC buttons through it. A generated long-TOC EPUB fixture proves ordering without committing an official sample binary.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, `PublicationSession`, `EPUBTestFixtures`

---

### Task 1: Add a long-TOC fixture and red ordering test

**Files:**
- Create: `Tests/iOS/yuedu appTests/EPUBTestFixtures+LongTOC.swift`
- Create: `Tests/iOS/yuedu appTests/ReaderTOCSelectionTimingTests.swift`

- [ ] **Step 1: Create the deterministic 80-entry fixture**

Add an `EPUBTestFixtures` extension that generates its manifest, spine, nav,
and XHTML entries in memory. Keep the official EPUB out of the test target.

```swift
import Foundation

extension EPUBTestFixtures {
    static func longTOC(chapterCount: Int = 80) -> Sample {
        precondition(chapterCount > 1)
        let manifest = (0..<chapterCount).map {
            #"<item id="c\#($0)" href="text/c\#($0).xhtml" media-type="application/xhtml+xml"/>"#
        }.joined(separator: "\n")
        let spine = (0..<chapterCount).map {
            #"<itemref idref="c\#($0)"/>"#
        }.joined(separator: "\n")
        let navItems = (0..<chapterCount).map {
            #"<li><a href="text/c\#($0).xhtml">Chapter \#($0 + 1)</a></li>"#
        }.joined(separator: "\n")

        var entries: [String: Data] = [
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
                <dc:identifier id="id">urn:yuedu:long-toc</dc:identifier>
                <dc:title>Long TOC</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                \(manifest)
              </manifest>
              <spine>\(spine)</spine>
            </package>
            """.utf8),
            "EPUB/nav.xhtml": Data(xhtml(
                title: "Contents",
                body: #"<nav epub:type="toc"><ol>\#(navItems)</ol></nav>"#
            ).utf8),
        ]
        for index in 0..<chapterCount {
            entries["EPUB/text/c\(index).xhtml"] = Data(xhtml(
                title: "Chapter \(index + 1)",
                body: "<h1>Chapter \(index + 1)</h1><p>Body \(index + 1)</p>"
            ).utf8)
        }
        return Sample(entries: entries)
    }
}
```

- [ ] **Step 2: Write the failing selection-order test**

The test must use the fixture's final TOC entry and assert that dismissal is
observable before the deferred navigation closure runs.

```swift
import Foundation
import Testing
@testable import yuedu_app

struct ReaderTOCSelectionTimingTests {
    @Test @MainActor
    func longTOCSelectionDismissesBeforeNavigation() async throws {
        let sample = EPUBTestFixtures.longTOC()
        let url = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let chapters = ReaderTOCChapterMapper.chapters(
            from: session.tocEntries,
            session: session
        )
        let target = try #require(chapters.last)
        var isPresented = true
        var events: [String] = []

        await confirmation("deferred navigation runs once") { navigated in
            let navigationTask = ReaderTOCSelectionAction.perform(
                chapter: target,
                dismiss: {
                    isPresented = false
                    events.append("dismiss")
                },
                navigate: { selected in
                    events.append("navigate:\(selected.index)")
                    navigated()
                }
            )

            #expect(isPresented == false)
            #expect(events == ["dismiss"])
            await navigationTask.value
        }

        #expect(events == ["dismiss", "navigate:\(target.index)"])
    }
}
```

- [ ] **Step 3: Run the focused test and verify RED**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderTOCSelectionTimingTests' \
  -parallel-testing-enabled NO
```

Expected: FAIL to compile because `ReaderTOCSelectionAction` does not exist.
Do not change the test to accept synchronous navigation.

### Task 2: Make dismissal-first behavior shared and deterministic

**Files:**
- Modify: `Modules/Features/Reader/ReaderTOCViews.swift`
- Test: `Tests/iOS/yuedu appTests/ReaderTOCSelectionTimingTests.swift`

- [ ] **Step 1: Add the main-actor action beside the TOC views**

```swift
@MainActor
enum ReaderTOCSelectionAction {
    @discardableResult
    static func perform(
        chapter: BookChapter,
        dismiss: @MainActor () -> Void,
        navigate: @MainActor @escaping (BookChapter) -> Void
    ) -> Task<Void, Never> {
        dismiss()
        return Task { @MainActor in
            await Task.yield()
            navigate(chapter)
        }
    }
}
```

The one-turn deferral is the boundary: the sheet binding changes before
`ReaderView.jumpToTOCEntry` can synchronously request a page controller. The
returned task makes the ordering test deterministic; production call sites can
ignore it through `@discardableResult`.

- [ ] **Step 2: Route both selection layouts through the action**

Replace the current `onSelectChapter`-then-dismiss blocks in both the vertical
callback and the regular list button with the same call:

```swift
ReaderTOCSelectionAction.perform(
    chapter: chapter,
    dismiss: { isPresented = false },
    navigate: onSelectChapter
)
```

Do not change the Done button or bookmark/highlight tabs.

- [ ] **Step 3: Run the focused test and verify GREEN**

Run the Task 1 command again.

Expected: `ReaderTOCSelectionTimingTests` passes; the confirmation is invoked
exactly once and the final event sequence is dismissal then navigation.

- [ ] **Step 4: Commit the regression and fix**

```bash
git add \
  Modules/Features/Reader/ReaderTOCViews.swift \
  'Tests/iOS/yuedu appTests/EPUBTestFixtures+LongTOC.swift' \
  'Tests/iOS/yuedu appTests/ReaderTOCSelectionTimingTests.swift'
git commit -m "fix: dismiss EPUB TOC before navigation"
```

### Task 3: Capture official evidence and update the matrix

**Files:**
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-001/README.md`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-001/before.png`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-001/after.png`
- Modify: `docs/build-week/epub3/compatibility-matrix.md`

- [ ] **Step 1: Capture the same official checkpoint before and after**

Use `accessible-epub3` on iPhone 17 Pro Max / iOS 27.0 / light theme / paged
mode / default typography. From its TOC select the preface target. Capture the
baseline while the sheet remains presented after the tap, and the fixed build
after the sheet dismisses and the preface body is visible. Use the exact same
orientation and crop.

- [ ] **Step 2: Write the evidence README with exact fields**

```markdown
# BW-EPUB3-001 — TOC dismissal before navigation

- Sample/checkpoint: accessible-epub3 / select preface from the TOC
- Sample checksum: 67f75b8e3cd1abe4bb143d91d5424191d5af3115c9d26ff029a38e19f8d16feb
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: paste the 40-character output of `git rev-parse HEAD` for the Task 2 fix commit
- Fixture: `EPUBTestFixtures+LongTOC.swift` / `longTOC(chapterCount:)`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/ReaderTOCSelectionTimingTests' -parallel-testing-enabled NO`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / light, paged, default typography
- Expected behavior: the TOC sheet dismisses before the selected preface navigation begins
- Observed behavior: baseline remained in the sheet; the fixed build dismisses first and shows the preface
- Official content visible: yes
- License attribution: CC BY-SA 3.0 (official catalog default; no sample-specific exception listed); source: https://idpf.github.io/epub3-samples/30/samples.html#accessible-epub3
```

Replace the After commit instruction with the command's exact SHA before
running `matrix-check`.

- [ ] **Step 3: Update every verified row in the shared failure family**

For `accessible-epub3`, `childrens-literature`, `linear-algebra`, and
`moby-dick`, update only checkpoints re-run after the fix. Set `Final outcome`
to `build-week-fixed` only where all required checkpoints now pass; otherwise
retain an honest failing or not-run outcome. Every fixed row links
`BW-EPUB3-001`, the focused test, its evidence directory, and the fix SHA.

- [ ] **Step 4: Validate evidence, rerun the corpus, and commit**

```bash
python3 scripts/epub3_samples.py matrix-check
python3 -m unittest discover -s Tests/Tools -p 'test_epub3_samples.py' -v
git diff --check
```

Then run the current corpus command from `docs/build-week/epub3/README.md` and
confirm 42 sample tests ran with zero skips. Commit only after the relevant
official rows and screenshots match the focused test:

```bash
git add docs/build-week/epub3/compatibility-matrix.md \
  docs/build-week/epub3/evidence/BW-EPUB3-001
git commit -m "docs: record EPUB TOC dismissal evidence"
```
