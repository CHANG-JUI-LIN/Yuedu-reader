# Reader Refresh Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the scattered paged/scroll reader refresh paths with one renderer-owned transaction pipeline that updates visible content only once, preserves stable reading position, and covers every chapter-title setting.

**Architecture:** `EPUBPageRenderer` owns refresh transaction identity, engine routing, stale-mode revisions, and visible-commit completion. `ReaderView` creates one immutable render-settings snapshot and submits refresh intent; the existing paged and scroll UIKit hosts are the two adapters that acknowledge a transaction after applying visible output.

**Tech Stack:** Swift 6, SwiftUI, UIKit, Combine, CoreText, Swift Testing, Xcode 16.

---

## File Map

**Create**

- `Modules/Core/ReaderCore/ReaderRenderRefresh.swift` — refresh request, result, mode, intent, visible-commit, and fingerprint value types.
- `Modules/Features/Reader/ReaderRenderSettingsSnapshotBuilder.swift` — the one builder for paged and scroll `ReaderRenderSettings`.
- `Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift` — renderer transaction, cancellation, routing, and visible-commit tests.
- `Tests/iOS/yuedu appTests/ReaderRenderSettingsSnapshotTests.swift` — settings geometry and chapter-title identity tests.

**Modify**

- `Modules/Core/ReaderCore/EPUBPageRenderer.swift` — transaction ownership, revision tracking, engine routing, visible-host acknowledgement.
- `Modules/Core/ReaderCore/CoreText/CoreTextScrollEngine.swift` — expose success from reslice and preserve the transaction position.
- `Modules/Features/Reader/CoreTextPagedView.swift` — apply pending paged visible commit and acknowledge after replacing the page controller.
- `Modules/Features/Reader/CoreTextScrollHostView.swift` — forward pending scroll visible commit.
- `Modules/Features/Reader/CoreTextCollectionScrollViewController.swift` — consume one scroll transaction, reslice with its stable position, acknowledge after reload.
- `Modules/Features/Reader/ReaderView+PageBuilding.swift` — use one settings snapshot and submit renderer refresh requests.
- `Modules/Features/Reader/ReaderView+TXTVerticalScroll.swift` — remove the separate settings builder and token-driven reslice.
- `Modules/Features/Reader/ReaderView+OnlineChapterLoading.swift` — route chapter-ready changes through renderer transactions.
- `Modules/Features/Reader/ReaderView+Logic.swift` — route manual refresh completion through the same transaction.
- `Modules/Features/Reader/ReaderView.swift` — replace duplicate render observers, pass visible commits to both hosts, and route mode activation.
- `Modules/Features/Reader/ReaderViewModifiers.swift` — remove `ScrollConfigObserver`.
- `Modules/Features/Reader/ReaderSettingsView.swift` — remove manual `readerConfig.refresh.send` calls.
- `Modules/Features/Reader/ChapterTitleStyleSettingsView.swift` — rely on the style value mutation instead of a manual refresh send.
- `Targets/Yuedu/SharedApp/GlobalSettings.swift` — clear chapter-title font references when deleting a font.
- Existing reader tests listed in Task 7 — update assertions only where the new transaction contract changes an interface.

## Task 1: Define Refresh Transactions and Identity

**Files:**

- Create: `Modules/Core/ReaderCore/ReaderRenderRefresh.swift`
- Create: `Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift`

- [ ] **Step 1: Write failing tests for request identity and terminal results**

Add these tests first:

```swift
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader render refresh", .serialized)
@MainActor
struct ReaderRenderRefreshTests {
    @Test("refresh request keeps stable position and active mode")
    func requestKeepsStablePositionAndMode() {
        let request = ReaderRenderRefreshRequest(
            intent: .layout,
            mode: .scroll,
            settings: Self.settings(fontSize: 18),
            position: CoreTextReadingPosition(spineIndex: 3, charOffset: 144),
            viewportSize: CGSize(width: 390, height: 844)
        )

        #expect(request.mode == .scroll)
        #expect(request.position == CoreTextReadingPosition(spineIndex: 3, charOffset: 144))
        #expect(request.intent == .layout)
    }

    @Test("terminal result distinguishes completion supersession and failure")
    func terminalResultsAreDistinct() {
        #expect(ReaderRenderRefreshResult.completed(transactionID: 4).isCompleted)
        #expect(!ReaderRenderRefreshResult.superseded(transactionID: 4).isCompleted)
        #expect(!ReaderRenderRefreshResult.failed(
            transactionID: 4,
            failure: .engineUnavailable(.paged)
        ).isCompleted)
    }

    private static func settings(fontSize: CGFloat) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: fontSize,
            lineHeightMultiple: 1.6,
            lineSpacing: 10,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero
        )
    }
}
```

- [ ] **Step 2: Run the new class and verify RED**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderRefreshTests' \
  -parallel-testing-enabled NO
```

Expected: compilation fails because `ReaderRenderRefreshRequest`,
`ReaderRenderRefreshResult`, and related types do not exist.

- [ ] **Step 3: Add the refresh value types**

Create `ReaderRenderRefresh.swift` with:

```swift
import CoreGraphics
import Foundation

enum ReaderDisplayMode: Equatable {
    case paged
    case scroll
}

enum ReaderRenderRefreshIntent: Equatable {
    case layout
    case appearance
    case chapterContent(Int)
    case modeActivation
}

struct ReaderRenderRefreshRequest: Equatable {
    let intent: ReaderRenderRefreshIntent
    let mode: ReaderDisplayMode
    let settings: ReaderRenderSettings
    let position: CoreTextReadingPosition
    let viewportSize: CGSize
}

enum ReaderRenderRefreshFailure: Error, Equatable {
    case engineUnavailable(ReaderDisplayMode)
    case layoutUnavailable(Int)
    case scrollViewportUnavailable
    case scrollLayoutUnavailable(Int)
}

enum ReaderRenderRefreshResult: Equatable {
    case completed(transactionID: UInt64)
    case superseded(transactionID: UInt64)
    case failed(transactionID: UInt64, failure: ReaderRenderRefreshFailure)

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

struct ReaderVisibleRefreshCommit: Equatable {
    let transactionID: UInt64
    let mode: ReaderDisplayMode
    let position: CoreTextReadingPosition
}

enum ReaderVisibleRefreshOutcome: Equatable {
    case applied
    case failed(ReaderRenderRefreshFailure)
}
```

- [ ] **Step 4: Run the new class and verify GREEN**

Run the command from Step 2.

Expected: `ReaderRenderRefreshTests` passes.

- [ ] **Step 5: Commit Task 1**

```bash
git add Modules/Core/ReaderCore/ReaderRenderRefresh.swift \
  'Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift'
git commit -m "test: define reader refresh transaction contract"
```

## Task 2: Build One Render Settings Snapshot

**Files:**

- Create: `Modules/Features/Reader/ReaderRenderSettingsSnapshotBuilder.swift`
- Create: `Tests/iOS/yuedu appTests/ReaderRenderSettingsSnapshotTests.swift`
- Modify: `Modules/Features/Reader/ReaderView+PageBuilding.swift`
- Modify: `Modules/Features/Reader/ReaderView+TXTVerticalScroll.swift`

- [ ] **Step 1: Write failing geometry and title-identity tests**

Create tests that use a fixed input and compare both modes:

```swift
import Testing
import UIKit
@testable import yuedu_app

@Suite("Reader render settings snapshot", .serialized)
@MainActor
struct ReaderRenderSettingsSnapshotTests {
    @Test("paged and scroll snapshots share typography and differ only in explicit geometry")
    func modeGeometryIsExplicit() {
        let input = Self.input()
        let paged = ReaderRenderSettingsSnapshotBuilder.make(
            input: input,
            surface: .paged(
                contentInsets: UIEdgeInsets(top: 42, left: 24, bottom: 58, right: 24),
                marginV: 16,
                footerHeight: 22
            )
        )
        let scroll = ReaderRenderSettingsSnapshotBuilder.make(
            input: input,
            surface: .scroll(
                contentInsets: UIEdgeInsets(top: 51, left: 24, bottom: 46, right: 24),
                marginV: 18,
                footerHeight: 24
            )
        )

        #expect(paged.fontSize == scroll.fontSize)
        #expect(paged.fontPostScriptName == scroll.fontPostScriptName)
        #expect(paged.chapterTitleStyle == scroll.chapterTitleStyle)
        #expect(paged.contentInsets != scroll.contentInsets)
    }

    @Test(arguments: ChapterTitleStyleMutation.allCases)
    func everyChapterTitleFieldChangesSettingsIdentity(
        mutation: ChapterTitleStyleMutation
    ) {
        let original = ReaderRenderSettingsSnapshotBuilder.make(
            input: Self.input(),
            surface: Self.surface
        )
        var changedInput = Self.input()
        changedInput.chapterTitleStyle = mutation.apply(to: changedInput.chapterTitleStyle)
        let changed = ReaderRenderSettingsSnapshotBuilder.make(
            input: changedInput,
            surface: Self.surface
        )

        #expect(original != changed)
    }
}
```

In the same test file, define `ChapterTitleStyleMutation: CaseIterable` with
fourteen cases. Each `apply(to:)` branch must change exactly one field:
`visible`, `size`, `topSpacing`, `bottomSpacing`, `weight`, `alignment`,
`followsBodyFont`, `splitEnabled`, `numberRelativeSize`,
`numberFontPostScript`, `nameFontPostScript`, `advancedCSSEnabled`,
`lightTemplate`, and `darkTemplate`.

Use this complete mutation helper:

```swift
private enum ChapterTitleStyleMutation: CaseIterable {
    case visible, size, topSpacing, bottomSpacing, weight, alignment
    case followsBodyFont, splitEnabled, numberRelativeSize
    case numberFontPostScript, nameFontPostScript
    case advancedCSSEnabled, lightTemplate, darkTemplate

    func apply(to original: ChapterTitleStyle) -> ChapterTitleStyle {
        var style = original
        switch self {
        case .visible: style.visible.toggle()
        case .size: style.size += 1
        case .topSpacing: style.topSpacing += 1
        case .bottomSpacing: style.bottomSpacing += 1
        case .weight: style.weight = style.weight == .bold ? .regular : .bold
        case .alignment: style.alignment = style.alignment == .left ? .right : .left
        case .followsBodyFont: style.followsBodyFont.toggle()
        case .splitEnabled: style.splitEnabled.toggle()
        case .numberRelativeSize: style.numberRelativeSize = 0.7
        case .numberFontPostScript: style.numberFontPostScript = "Courier"
        case .nameFontPostScript: style.nameFontPostScript = "Courier-Bold"
        case .advancedCSSEnabled: style.advancedCSSEnabled.toggle()
        case .lightTemplate: style.lightTemplate += "<span>light</span>"
        case .darkTemplate: style.darkTemplate += "<span>dark</span>"
        }
        return style
    }
}
```

Define `input()` and `surface` with concrete values:

```swift
private extension ReaderRenderSettingsSnapshotTests {
    static let surface = ReaderRenderSurface.paged(
        contentInsets: UIEdgeInsets(top: 42, left: 24, bottom: 58, right: 24),
        marginV: 16,
        footerHeight: 22
    )

    static func input() -> ReaderRenderSettingsSnapshotInput {
        ReaderRenderSettingsSnapshotInput(
            theme: "sepia",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.6,
            lineSpacing: 10.8,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            writingMode: .horizontal,
            fontPostScriptName: "Courier",
            isBold: false,
            chapterTitleStyle: .default,
            readerBackgroundImageURL: nil,
            dialogueHighlightColor: nil,
            dialogueBoxColor: nil
        )
    }
}
```

- [ ] **Step 2: Run snapshot tests and verify RED**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderSettingsSnapshotTests' \
  -parallel-testing-enabled NO
```

Expected: compilation fails because the snapshot builder types do not exist.

- [ ] **Step 3: Implement the snapshot builder**

Create:

```swift
import UIKit

struct ReaderRenderSettingsSnapshotInput {
    let theme: String
    let textColor: UIColor
    let backgroundColor: UIColor
    let fontSize: CGFloat
    let lineHeightMultiple: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let letterSpacing: CGFloat
    let marginH: CGFloat
    let writingMode: ReaderWritingMode
    let fontPostScriptName: String?
    let isBold: Bool
    var chapterTitleStyle: ChapterTitleStyle
    let readerBackgroundImageURL: URL?
    let dialogueHighlightColor: UIColor?
    let dialogueBoxColor: UIColor?
}

enum ReaderRenderSurface {
    case paged(contentInsets: UIEdgeInsets, marginV: CGFloat, footerHeight: CGFloat)
    case scroll(contentInsets: UIEdgeInsets, marginV: CGFloat, footerHeight: CGFloat)
}

enum ReaderRenderSettingsSnapshotBuilder {
    static func make(
        input: ReaderRenderSettingsSnapshotInput,
        surface: ReaderRenderSurface
    ) -> ReaderRenderSettings {
        let geometry: (UIEdgeInsets, CGFloat, CGFloat)
        switch surface {
        case .paged(let insets, let marginV, let footerHeight),
             .scroll(let insets, let marginV, let footerHeight):
            geometry = (insets, marginV, footerHeight)
        }
        return ReaderRenderSettings(
            theme: input.theme,
            textColor: input.textColor,
            backgroundColor: input.backgroundColor,
            fontSize: input.fontSize,
            lineHeightMultiple: input.lineHeightMultiple,
            lineSpacing: input.lineSpacing,
            paragraphSpacing: input.paragraphSpacing,
            letterSpacing: input.letterSpacing,
            marginH: input.marginH,
            marginV: geometry.1,
            footerHeight: geometry.2,
            contentInsets: geometry.0,
            writingMode: input.writingMode,
            fontPostScriptName: input.fontPostScriptName,
            isBold: input.isBold,
            chapterTitleStyle: input.chapterTitleStyle,
            readerBackgroundImageURL: input.readerBackgroundImageURL,
            dialogueHighlightColor: input.dialogueHighlightColor,
            dialogueBoxColor: input.dialogueBoxColor
        )
    }
}
```

- [ ] **Step 4: Replace both ReaderView builders**

In `ReaderView+PageBuilding.swift`, replace `currentRenderSettings(marginH:)`
with:

```swift
func readerRenderSettings(for mode: ReaderDisplayMode) -> ReaderRenderSettings {
    let input = ReaderRenderSettingsSnapshotInput(
        theme: readerTheme.epubJSName,
        textColor: readerTheme.uiTextColor,
        backgroundColor: readerTheme.uiBackgroundColor,
        fontSize: readerConfig.fontSize,
        lineHeightMultiple: max(1, readerConfig.lineHeightMultiple),
        lineSpacing: readerConfig.lineSpacing,
        paragraphSpacing: readerConfig.paragraphSpacing,
        letterSpacing: readerConfig.letterSpacing,
        marginH: effectivePageMarginH,
        writingMode: effectiveWritingMode,
        fontPostScriptName: UserReaderFontResolver.selectedPostScriptName,
        isBold: readerConfig.readerFontBold,
        chapterTitleStyle: readerConfig.chapterTitleStyle,
        readerBackgroundImageURL: activeReaderBackgroundImageURL,
        dialogueHighlightColor: resolvedDialogueHighlightColor,
        dialogueBoxColor: resolvedDialogueBoxColor
    )
    switch mode {
    case .paged:
        let reservations = ReaderOverlayPaginationPolicy.insets(
            for: settings.readerOverlayLayout
        )
        return ReaderRenderSettingsSnapshotBuilder.make(
            input: input,
            surface: .paged(
                contentInsets: UIEdgeInsets(
                    top: CGFloat(reservations.top),
                    left: effectivePageMarginH,
                    bottom: CGFloat(reservations.bottom),
                    right: effectivePageMarginH
                ),
                marginV: systemVerticalPadding,
                footerHeight: footerOverlayHeight
            )
        )
    case .scroll:
        return ReaderRenderSettingsSnapshotBuilder.make(
            input: input,
            surface: .scroll(
                contentInsets: UIEdgeInsets(
                    top: ReaderLayoutMetrics.topInset(safeTop: effectiveReaderSafeTop),
                    left: effectivePageMarginH,
                    bottom: ReaderLayoutMetrics.bottomInset(
                        safeBottom: 0,
                        footerBottomPadding: readerConfig.footerBottomPadding,
                        footerTextGap: readerConfig.footerTextGap
                    ),
                    right: effectivePageMarginH
                ),
                marginV: readerConfig.pageMarginV,
                footerHeight: ReaderLayoutMetrics.footerHeight
            )
        )
    }
}
```

Add `resolvedDialogueHighlightColor` and `resolvedDialogueBoxColor` computed
properties next to this function so the color conditions exist once. Replace
every call to `currentRenderSettings` or `buildRenderSettings` with
`readerRenderSettings(for:)`, then delete `buildRenderSettings`.

- [ ] **Step 5: Run snapshot and existing settings tests**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderSettingsSnapshotTests' \
  -only-testing:'yuedu appTests/UserFontSettingsTests' \
  -only-testing:'yuedu appTests/ChapterTitleAttributedBuilderTests' \
  -parallel-testing-enabled NO
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add Modules/Features/Reader/ReaderRenderSettingsSnapshotBuilder.swift \
  Modules/Features/Reader/ReaderView+PageBuilding.swift \
  Modules/Features/Reader/ReaderView+TXTVerticalScroll.swift \
  'Tests/iOS/yuedu appTests/ReaderRenderSettingsSnapshotTests.swift'
git commit -m "refactor: unify reader render settings snapshots"
```

## Task 3: Move Refresh Ownership into EPUBPageRenderer

**Files:**

- Modify: `Modules/Core/ReaderCore/EPUBPageRenderer.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/CoreTextScrollEngine.swift`
- Modify: `Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift`

- [ ] **Step 1: Write failing renderer transaction tests**

Append tests that load a real one-chapter builder through `loadTXT`:

```swift
@Test("newer layout refresh supersedes the older transaction")
func newerRefreshSupersedesOlderTransaction() async throws {
    let renderer = EPUBPageRenderer()
    renderer.loadTXT(
        attributedBuilder: MutableReaderRefreshBuilder(body: "Body"),
        bookIdentifier: UUID().uuidString,
        renderSize: CGSize(width: 320, height: 480),
        settings: Self.settings(fontSize: 18)
    )
    await waitUntilPagedReady(renderer)

    let first = Task {
        await renderer.refresh(Self.request(fontSize: 19))
    }
    let firstCommit = await waitForVisibleCommit(renderer)
    let second = Task {
        await renderer.refresh(Self.request(fontSize: 22))
    }
    let secondCommit = await waitForVisibleCommit(
        renderer,
        after: firstCommit.transactionID
    )
    renderer.finishVisibleRefresh(
        transactionID: secondCommit.transactionID,
        outcome: .applied
    )

    #expect(await first.value == .superseded(transactionID: 1))
    #expect((await second.value).isCompleted)
    #expect((renderer.engine as? CoreTextPageEngine)?.renderSettings.fontSize == 22)
    #expect(renderer.scrollEngine?.renderSettings.fontSize == 22)
}

@Test("chapter refresh invalidates the shared document once")
func chapterRefreshInvalidatesSharedDocumentOnce() async throws {
    let builder = MutableReaderRefreshBuilder(body: "Body")
    let renderer = EPUBPageRenderer()
    renderer.loadTXT(
        attributedBuilder: builder,
        bookIdentifier: UUID().uuidString,
        renderSize: CGSize(width: 320, height: 480),
        settings: Self.settings(fontSize: 18)
    )
    await waitUntilPagedReady(renderer)

    let task = Task {
        await renderer.refresh(ReaderRenderRefreshRequest(
            intent: .chapterContent(0),
            mode: .paged,
            settings: Self.settings(fontSize: 18),
            position: .chapterStart(0),
            viewportSize: CGSize(width: 320, height: 480)
        ))
    }
    let commit = await waitForVisibleCommit(renderer)
    renderer.finishVisibleRefresh(
        transactionID: commit.transactionID,
        outcome: .applied
    )

    #expect((await task.value).isCompleted)
    #expect(builder.buildCount == 2)
}
```

Add this builder and polling helper to the test file:

```swift
@MainActor
private final class MutableReaderRefreshBuilder: AttributedStringBuilding {
    let chapterCount = 1
    var body: String
    private(set) var buildCount = 0

    init(body: String) {
        self.body = body
    }

    func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
    func chapterDataSize(at index: Int) async -> Int { body.utf8.count }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        buildCount += 1
        return AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: body,
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}

@MainActor
private func waitForVisibleCommit(
    _ renderer: EPUBPageRenderer,
    after transactionID: UInt64 = 0
) async -> ReaderVisibleRefreshCommit {
    while true {
        if let commit = renderer.pendingVisibleRefreshCommit,
           commit.transactionID > transactionID {
            return commit
        }
        await Task.yield()
    }
}

@MainActor
private func waitUntilPagedReady(_ renderer: EPUBPageRenderer) async {
    while !renderer.isCoreTextReady {
        await Task.yield()
    }
}

private extension ReaderRenderRefreshTests {
    static func request(fontSize: CGFloat) -> ReaderRenderRefreshRequest {
        ReaderRenderRefreshRequest(
            intent: .layout,
            mode: .paged,
            settings: settings(fontSize: fontSize),
            position: .chapterStart(0),
            viewportSize: CGSize(width: 320, height: 480)
        )
    }
}
```

- [ ] **Step 2: Run renderer tests and verify RED**

Run the Task 1 test command.

Expected: compilation fails because renderer refresh ownership is absent.

- [ ] **Step 3: Add renderer transaction state**

Add these properties to `EPUBPageRenderer`:

```swift
@Published private(set) var pendingVisibleRefreshCommit: ReaderVisibleRefreshCommit?

private var nextRefreshTransactionID: UInt64 = 0
private var currentRefreshTransactionID: UInt64 = 0
private var visibleRefreshContinuations:
    [UInt64: CheckedContinuation<ReaderRenderRefreshResult, Never>] = [:]
private var latestRenderSettings: ReaderRenderSettings?
private var settingsRevision: UInt64 = 0
private var contentRevision: UInt64 = 0
private var pagedAppliedSettingsRevision: UInt64 = 0
private var scrollAppliedSettingsRevision: UInt64 = 0
private var pagedAppliedContentRevision: UInt64 = 0
private var scrollAppliedContentRevision: UInt64 = 0
```

Add `beginRefreshTransaction`, `supersedePendingVisibleRefresh`, and
`finishVisibleRefresh`:

```swift
private func beginRefreshTransaction() -> UInt64 {
    nextRefreshTransactionID &+= 1
    currentRefreshTransactionID = nextRefreshTransactionID
    if let pending = pendingVisibleRefreshCommit,
       let continuation = visibleRefreshContinuations.removeValue(
           forKey: pending.transactionID
       ) {
        continuation.resume(returning: .superseded(
            transactionID: pending.transactionID
        ))
    }
    pendingVisibleRefreshCommit = nil
    engine?.cancelPendingWork()
    return currentRefreshTransactionID
}

func finishVisibleRefresh(
    transactionID: UInt64,
    outcome: ReaderVisibleRefreshOutcome
) {
    guard pendingVisibleRefreshCommit?.transactionID == transactionID,
          let continuation = visibleRefreshContinuations.removeValue(
              forKey: transactionID
          )
    else { return }
    pendingVisibleRefreshCommit = nil
    switch outcome {
    case .applied:
        continuation.resume(returning: .completed(transactionID: transactionID))
    case .failed(let failure):
        continuation.resume(returning: .failed(
            transactionID: transactionID,
            failure: failure
        ))
    }
}
```

- [ ] **Step 4: Implement the single refresh interface**

Add:

```swift
func refresh(
    _ request: ReaderRenderRefreshRequest
) async -> ReaderRenderRefreshResult {
    let transactionID = beginRefreshTransaction()
    if latestRenderSettings != request.settings {
        latestRenderSettings = request.settings
        settingsRevision &+= 1
    }
    updateRenderSettings(request.settings)
    if case .chapterContent = request.intent {
        contentRevision &+= 1
    }

    let failure = await prepareRefresh(
        request,
        transactionID: transactionID
    )
    guard transactionID == currentRefreshTransactionID else {
        return .superseded(transactionID: transactionID)
    }
    if let failure {
        return .failed(transactionID: transactionID, failure: failure)
    }

    return await withCheckedContinuation { continuation in
        visibleRefreshContinuations[transactionID] = continuation
        pendingVisibleRefreshCommit = ReaderVisibleRefreshCommit(
            transactionID: transactionID,
            mode: request.mode,
            position: request.position
        )
    }
}
```

Implement `prepareRefresh` with these exact routing rules:

- paged layout: `await engine.invalidateLayout(newSize:)`;
- paged appearance: `engine.applyThemeChange`, no pagination;
- paged chapter content: `await engine.notifyChapterDataChanged(at:)`;
- paged mode activation: invalidate only when the paged revision is stale;
- scroll layout/appearance: update settings and let the scroll host perform
  the transaction reslice;
- scroll chapter content: invalidate the target chapter document before host
  reslice when it is the visible chapter; use `retryChapterIfNeeded` for a
  non-visible pending chapter;
- scroll mode activation: reslice only when its settings/content revision is
  stale.

After a successful active rebuild, update that engine's applied settings and
content revisions. Return `.layoutUnavailable(position.spineIndex)` when paged
layout completion did not produce the target layout.

Store the request alongside its continuation. Applied revisions advance only
inside `finishVisibleRefresh(..., outcome: .applied)`, never when the engine
merely starts work:

```swift
private var visibleRefreshRequests: [UInt64: ReaderRenderRefreshRequest] = [:]
```

- [ ] **Step 5: Make scroll reslice report success**

Change `CoreTextScrollEngine.reslice` to:

```swift
@discardableResult
func reslice(
    restoreAt chapterIndex: Int,
    contentWidth: CGFloat,
    imageContentWidth: CGFloat? = nil,
    restorePosition: CoreTextReadingPosition? = nil
) async -> Bool {
    // existing replacement build
    guard generation == resliceGeneration, !Task.isCancelled else {
        return false
    }
    // existing state commit and reset event
    return chapterRanges[chapterIndex]?.isEmpty == false
}
```

Existing non-transaction callers discard the Boolean with `_ = await`. The
transaction scroll host converts `false` to
`.failed(.scrollLayoutUnavailable(chapterIndex))`.

- [ ] **Step 6: Run renderer, document-store, and scroll tests**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderRefreshTests' \
  -only-testing:'yuedu appTests/ChapterDocumentStoreTests' \
  -only-testing:'yuedu appTests/CoreTextScrollTests' \
  -parallel-testing-enabled NO
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit Task 3**

```bash
git add Modules/Core/ReaderCore/EPUBPageRenderer.swift \
  Modules/Core/ReaderCore/CoreText/CoreTextScrollEngine.swift \
  'Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift'
git commit -m "refactor: centralize reader refresh transactions"
```

## Task 4: Add the Visible-Commit Host Seam

**Files:**

- Modify: `Modules/Features/Reader/CoreTextPagedView.swift`
- Modify: `Modules/Features/Reader/CoreTextScrollHostView.swift`
- Modify: `Modules/Features/Reader/CoreTextCollectionScrollViewController.swift`
- Modify: `Modules/Features/Reader/ReaderView.swift`
- Modify: `Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift`
- Modify: `Tests/iOS/yuedu appTests/CoreTextScrollTests.swift`

- [ ] **Step 1: Write failing paged and scroll host tests**

Add a paged coordinator test that supplies a commit at
`(spineIndex: 0, charOffset: 20)`, applies it to a real
`UIPageViewController`, and asserts:

```swift
#expect(coordinator.lastAppliedRefreshTransactionID == 7)
#expect(appliedTransactionIDs == [7])
#expect(
    (pageViewController.viewControllers?.first as? CoreTextReadingPositionProviding)?
        .coreTextReadingPosition?.charOffset == 20
)
```

Add a scroll-controller test that invokes:

```swift
controller.applyVisibleRefresh(
    ReaderVisibleRefreshCommit(
        transactionID: 9,
        mode: .scroll,
        position: CoreTextReadingPosition(spineIndex: 0, charOffset: 40)
    )
) { transactionID, outcome in
    if outcome == .applied {
        appliedTransactionIDs.append(transactionID)
    }
}
```

Wait for completion with `Task.yield()`, then assert:

```swift
#expect(appliedTransactionIDs == [9])
#expect(controller.lastAppliedRefreshTransactionID == 9)
#expect(engine.isReady)
```

- [ ] **Step 2: Run the two test classes and verify RED**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderRefreshTests' \
  -only-testing:'yuedu appTests/CoreTextScrollTests' \
  -parallel-testing-enabled NO
```

Expected: compilation fails because visible commits cannot be applied.

- [ ] **Step 3: Make the paged host consume commits**

Add these inputs to `CoreTextPageEngineView`:

```swift
let visibleRefreshCommit: ReaderVisibleRefreshCommit?
let onVisibleRefreshFinished: (UInt64, ReaderVisibleRefreshOutcome) -> Void
```

Store `lastAppliedRefreshTransactionID` in its coordinator. In
`updateUIViewController`, before ordinary position commands:

```swift
if let commit = visibleRefreshCommit,
   commit.mode == .paged,
   context.coordinator.lastAppliedRefreshTransactionID != commit.transactionID {
    let target = context.coordinator.displayViewController(for: commit.position)
    _ = context.coordinator.setPage(
        target,
        on: uiViewController,
        layoutNow: true
    )
    context.coordinator.lastAppliedRefreshTransactionID = commit.transactionID
    onVisibleRefreshFinished(commit.transactionID, .applied)
    return
}
```

Pass `epubRenderer.pendingVisibleRefreshCommit` and
`epubRenderer.finishVisibleRefresh` from both fixed and reflowable paged call
sites in `ReaderView`.

- [ ] **Step 4: Make the scroll host consume commits**

Replace `resliceToken` with:

```swift
let visibleRefreshCommit: ReaderVisibleRefreshCommit?
let onVisibleRefreshFinished: (UInt64, ReaderVisibleRefreshOutcome) -> Void
```

In `CoreTextScrollHostView.updateUIViewController`, forward each new scroll
commit once:

```swift
if let commit = visibleRefreshCommit,
   commit.mode == .scroll,
   context.coordinator.lastRefreshTransactionID != commit.transactionID {
    context.coordinator.lastRefreshTransactionID = commit.transactionID
    collectionVC.applyVisibleRefresh(commit, completion: onVisibleRefreshFinished)
}
```

In `CoreTextCollectionScrollViewController`, replace
`onResliceCompleted` and token-owned completion with:

```swift
private(set) var lastAppliedRefreshTransactionID: UInt64 = 0

func applyVisibleRefresh(
    _ commit: ReaderVisibleRefreshCommit,
    completion: @escaping (UInt64, ReaderVisibleRefreshOutcome) -> Void
) {
    guard commit.transactionID != lastAppliedRefreshTransactionID else { return }
    requestReslice(
        at: commit.position.spineIndex,
        charOffset: commit.position.charOffset
    ) { [weak self] succeeded in
        guard let self else { return }
        guard succeeded else {
            completion(
                commit.transactionID,
                .failed(.scrollLayoutUnavailable(commit.position.spineIndex))
            )
            return
        }
        self.lastAppliedRefreshTransactionID = commit.transactionID
        completion(commit.transactionID, .applied)
    }
}
```

The existing reslice task remains latest-wins. Its completion executes only
after the engine reset has been consumed, collection data reloaded, and
`applyPendingInitialScrollIfPossible()` has run.

- [ ] **Step 5: Run host and scroll tests**

Run the command from Step 2.

Expected: all selected tests pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add Modules/Features/Reader/CoreTextPagedView.swift \
  Modules/Features/Reader/CoreTextScrollHostView.swift \
  Modules/Features/Reader/CoreTextCollectionScrollViewController.swift \
  Modules/Features/Reader/ReaderView.swift \
  'Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift' \
  'Tests/iOS/yuedu appTests/CoreTextScrollTests.swift'
git commit -m "refactor: acknowledge visible reader refresh commits"
```

## Task 5: Replace Duplicate Setting Refresh Paths

**Files:**

- Modify: `Modules/Features/Reader/ReaderView+PageBuilding.swift`
- Modify: `Modules/Features/Reader/ReaderView+TXTVerticalScroll.swift`
- Modify: `Modules/Features/Reader/ReaderViewModifiers.swift`
- Modify: `Modules/Features/Reader/ReaderView.swift`
- Modify: `Modules/Features/Reader/ReaderSettingsView.swift`
- Modify: `Modules/Features/Reader/ChapterTitleStyleSettingsView.swift`
- Modify: `Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift`

- [ ] **Step 1: Write failing settings-routing integration tests**

Add parameterized renderer tests for:

```swift
enum ReaderSettingMutation: CaseIterable {
    case fontSize
    case bold
    case readerFont
    case lineHeight
    case letterSpacing
    case paragraphSpacing
    case pageMargin
    case footerSpacing
    case chapterTitleStyle
    case theme
}
```

For every mutation, submit the resulting settings first in `.paged`, then in
`.scroll`, acknowledge the visible commit, and assert:

```swift
#expect(result.isCompleted)
#expect((renderer.engine as? CoreTextPageEngine)?.renderSettings == changedSettings)
#expect(renderer.scrollEngine?.renderSettings == changedSettings)
```

Add a rapid three-change test and assert only the third transaction is
acknowledged.

- [ ] **Step 2: Run renderer tests and verify RED**

Run the Task 1 test command.

Expected: at least the scroll-host and rapid-setting cases fail through the old
observer/token paths.

- [ ] **Step 3: Add two value observers in ReaderView**

Add one computed active snapshot:

```swift
var activeReaderRenderSettings: ReaderRenderSettings {
    readerRenderSettings(for: effectiveScrollMode ? .scroll : .paged)
}
```

Add one `ReaderDocumentStyleFingerprint: Equatable` in
`ReaderRenderRefresh.swift` containing the current comment-bubble, underline,
and dialogue-box style values that are still read by CoreText drawing/building
code.

Replace the sixteen separate render-affecting `onChanged` blocks and
`onReceive(readerConfig.refresh)` with:

```swift
.onChanged(of: activeReaderRenderSettings) { settings in
    submitReaderRefresh(
        intent: .layout,
        settings: settings
    )
}
.onChanged(of: readerDocumentStyleFingerprint) { _ in
    submitReaderRefresh(
        intent: .chapterContent(currentChapterIndex),
        settings: activeReaderRenderSettings
    )
}
```

`submitReaderRefresh` captures the current stable position, starts one task,
and handles only the terminal result. It does not call an engine method.

- [ ] **Step 4: Remove old setting triggers**

Delete:

- `ScrollConfigObserver`;
- `scheduleScrollReslice`;
- `scrollResliceToken`;
- manual `readerConfig.refresh.send(.layout)` calls from font, underline,
  layout-preset, and chapter-title settings actions;
- `performUnifiedRelayout`, `applyUnifiedAppearanceUpdate`, and
  `forceReaderRenderableContentRefresh` after all callers move to
  `submitReaderRefresh`.

Keep `ReaderConfig.refresh` only if a non-reader caller still consumes it.
Otherwise remove the subject and its send operations while retaining
persistence publishers.

- [ ] **Step 5: Run settings, font, title, and renderer tests**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderRefreshTests' \
  -only-testing:'yuedu appTests/ReaderRenderSettingsSnapshotTests' \
  -only-testing:'yuedu appTests/UserFontSettingsTests' \
  -only-testing:'yuedu appTests/ChapterTitleAttributedBuilderTests' \
  -parallel-testing-enabled NO
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit Task 5**

```bash
git add Modules/Core/ReaderCore/ReaderRenderRefresh.swift \
  Modules/Features/Reader/ReaderView+PageBuilding.swift \
  Modules/Features/Reader/ReaderView+TXTVerticalScroll.swift \
  Modules/Features/Reader/ReaderViewModifiers.swift \
  Modules/Features/Reader/ReaderView.swift \
  Modules/Features/Reader/ReaderSettingsView.swift \
  Modules/Features/Reader/ChapterTitleStyleSettingsView.swift \
  'Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift'
git commit -m "refactor: route reader settings through one refresh path"
```

## Task 6: Route Chapter Content, Manual Refresh, and Mode Activation

**Files:**

- Modify: `Modules/Features/Reader/ReaderView+OnlineChapterLoading.swift`
- Modify: `Modules/Features/Reader/ReaderView+Logic.swift`
- Modify: `Modules/Features/Reader/ReaderView.swift`
- Modify: `Targets/Yuedu/SharedApp/GlobalSettings.swift`
- Modify: `Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift`
- Modify: `Tests/iOS/yuedu appTests/UserFontSettingsTests.swift`

- [ ] **Step 1: Write failing content and mode-switch tests**

Add these tests, reusing `MutableReaderRefreshBuilder`,
`waitForVisibleCommit`, `waitUntilPagedReady`, and `Self.settings` from Task 3:

```swift
@Test("manual loading ends only after visible commit acknowledgement")
func manualLoadingWaitsForVisibleCommit() async {
    let renderer = EPUBPageRenderer()
    let builder = MutableReaderRefreshBuilder(body: "Fresh body")
    renderer.loadTXT(
        attributedBuilder: builder,
        bookIdentifier: UUID().uuidString,
        renderSize: CGSize(width: 320, height: 480),
        settings: Self.settings(fontSize: 18)
    )
    await waitUntilPagedReady(renderer)

    let task = Task {
        await renderer.refresh(ReaderRenderRefreshRequest(
            intent: .chapterContent(0),
            mode: .paged,
            settings: Self.settings(fontSize: 18),
            position: .chapterStart(0),
            viewportSize: CGSize(width: 320, height: 480)
        ))
    }
    let commit = await waitForVisibleCommit(renderer)

    #expect(renderer.pendingVisibleRefreshCommit == commit)
    renderer.finishVisibleRefresh(
        transactionID: commit.transactionID,
        outcome: .applied
    )
    #expect((await task.value).isCompleted)
}

@Test("content revision survives a superseding layout request")
func contentRevisionSurvivesLayoutSupersession() async throws {
    let renderer = EPUBPageRenderer()
    let builder = MutableReaderRefreshBuilder(body: "Old body")
    renderer.loadTXT(
        attributedBuilder: builder,
        bookIdentifier: UUID().uuidString,
        renderSize: CGSize(width: 320, height: 480),
        settings: Self.settings(fontSize: 18)
    )
    await waitUntilPagedReady(renderer)
    builder.body = "New body"

    let contentTask = Task {
        await renderer.refresh(ReaderRenderRefreshRequest(
            intent: .chapterContent(0),
            mode: .paged,
            settings: Self.settings(fontSize: 18),
            position: .chapterStart(0),
            viewportSize: CGSize(width: 320, height: 480)
        ))
    }
    let contentCommit = await waitForVisibleCommit(renderer)
    let layoutTask = Task {
        await renderer.refresh(Self.request(fontSize: 22))
    }
    let layoutCommit = await waitForVisibleCommit(
        renderer,
        after: contentCommit.transactionID
    )
    renderer.finishVisibleRefresh(
        transactionID: layoutCommit.transactionID,
        outcome: .applied
    )

    #expect(await contentTask.value == .superseded(
        transactionID: contentCommit.transactionID
    ))
    #expect((await layoutTask.value).isCompleted)
    let engine = try #require(renderer.engine as? CoreTextPageEngine)
    #expect(engine.layouts[0]?.attributedString.string == "New body")
    #expect(engine.renderSettings.fontSize == 22)
}

@Test("mode activation does not rebuild an up-to-date target twice")
func activationRefreshesOnlyStaleMode() async {
    let renderer = EPUBPageRenderer()
    let builder = MutableReaderRefreshBuilder(body: "Body")
    renderer.loadTXT(
        attributedBuilder: builder,
        bookIdentifier: UUID().uuidString,
        renderSize: CGSize(width: 320, height: 480),
        settings: Self.settings(fontSize: 18)
    )
    await waitUntilPagedReady(renderer)

    let request = ReaderRenderRefreshRequest(
        intent: .modeActivation,
        mode: .scroll,
        settings: Self.settings(fontSize: 18),
        position: .chapterStart(0),
        viewportSize: CGSize(width: 320, height: 480)
    )
    let first = Task { await renderer.refresh(request) }
    let firstCommit = await waitForVisibleCommit(renderer)
    _ = await renderer.scrollEngine?.reslice(
        restoreAt: 0,
        contentWidth: 288,
        restorePosition: .chapterStart(0)
    )
    renderer.finishVisibleRefresh(
        transactionID: firstCommit.transactionID,
        outcome: .applied
    )
    _ = await first.value
    let buildsAfterFirstActivation = builder.buildCount

    let second = Task { await renderer.refresh(request) }
    let secondCommit = await waitForVisibleCommit(
        renderer,
        after: firstCommit.transactionID
    )
    renderer.finishVisibleRefresh(
        transactionID: secondCommit.transactionID,
        outcome: .applied
    )
    _ = await second.value

    #expect(builder.buildCount == buildsAfterFirstActivation)
}
```

Add a font deletion test:

```swift
@Test("deleting a title font clears both segment references")
func deletingTitleFontClearsSegmentReferences() throws {
    let imported = try importAhemFixture()
    var style = ReaderConfig.shared.chapterTitleStyle
    style.followsBodyFont = false
    style.numberFontPostScript = imported.postScriptName
    style.nameFontPostScript = imported.postScriptName
    ReaderConfig.shared.chapterTitleStyle = style

    GlobalSettings.shared.deleteUserFont(imported)

    #expect(ReaderConfig.shared.chapterTitleStyle.numberFontPostScript == nil)
    #expect(ReaderConfig.shared.chapterTitleStyle.nameFontPostScript == nil)
}
```

- [ ] **Step 2: Run renderer and font tests and verify RED**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderRefreshTests' \
  -only-testing:'yuedu appTests/UserFontSettingsTests' \
  -parallel-testing-enabled NO
```

Expected: the new content/mode/font-reference assertions fail.

- [ ] **Step 3: Route chapter-ready changes through the renderer**

Replace direct paged `notifyChapterDataChanged`, scroll document invalidation,
scroll retry, and `rebuildPages` orchestration in
`applyChapterRefreshAction` with one task:

```swift
let result = await epubRenderer.refresh(
    ReaderRenderRefreshRequest(
        intent: .chapterContent(chapterIndex),
        mode: effectiveScrollMode ? .scroll : .paged,
        settings: activeReaderRenderSettings,
        position: currentStableReaderPosition,
        viewportSize: currentReaderRenderSize
    )
)
handleReaderRefreshResult(
    result,
    manuallyRefreshedChapter: chapterIndex
)
```

The result handler clears `manuallyRefreshingChapterIndex` only for
`.completed` or `.failed` belonging to the active manual refresh. It ignores
`.superseded` because the replacement transaction owns completion.

- [ ] **Step 4: Route mode switches through activation**

Keep position capture and session movement in `handleScrollModeChanged`, then
submit:

```swift
submitReaderRefresh(
    intent: .modeActivation,
    settings: readerRenderSettings(for: enabled ? .scroll : .paged),
    mode: enabled ? .scroll : .paged,
    position: position
)
```

Remove direct target-engine layout preparation from the mode-switch handler.
Navigation state remains `(spineIndex, charOffset)`.

- [ ] **Step 5: Clear deleted title-font references**

In `GlobalSettings.deleteUserFont`, after removing the reader/global
selection, mutate `ReaderConfig.shared.chapterTitleStyle`:

```swift
var titleStyle = ReaderConfig.shared.chapterTitleStyle
var changed = false
if titleStyle.numberFontPostScript == font.postScriptName {
    titleStyle.numberFontPostScript = nil
    changed = true
}
if titleStyle.nameFontPostScript == font.postScriptName {
    titleStyle.nameFontPostScript = nil
    changed = true
}
if changed {
    ReaderConfig.shared.chapterTitleStyle = titleStyle
}
```

- [ ] **Step 6: Run content, cache, mode, and font regressions**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderRenderRefreshTests' \
  -only-testing:'yuedu appTests/ChapterDocumentStoreTests' \
  -only-testing:'yuedu appTests/CoreTextScrollOnlineCacheTests' \
  -only-testing:'yuedu appTests/UserFontSettingsTests' \
  -only-testing:'yuedu appTests/ReaderChapterPresentationTests' \
  -parallel-testing-enabled NO
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit Task 6**

```bash
git add Modules/Features/Reader/ReaderView+OnlineChapterLoading.swift \
  Modules/Features/Reader/ReaderView+Logic.swift \
  Modules/Features/Reader/ReaderView.swift \
  Targets/Yuedu/SharedApp/GlobalSettings.swift \
  'Tests/iOS/yuedu appTests/ReaderRenderRefreshTests.swift' \
  'Tests/iOS/yuedu appTests/UserFontSettingsTests.swift'
git commit -m "refactor: unify chapter and mode refresh transactions"
```

## Task 7: Full Relevant Regression and Cleanup

**Files:**

- Modify only files implicated by failures from the commands below.
- Update: `docs/superpowers/plans/2026-07-30-reader-refresh-pipeline.md` — check completed steps after all commands pass.

- [ ] **Step 1: Verify obsolete paths are gone**

Run:

```bash
rg -n \
  'ScrollConfigObserver|scrollResliceToken|scheduleScrollReslice|onResliceCompleted|performUnifiedRelayout|forceReaderRenderableContentRefresh' \
  Modules/Features/Reader Modules/Core/ReaderCore
```

Expected: no matches.

Run:

```bash
rg -n 'readerConfig\\.refresh\\.send' Modules/Features/Reader
```

Expected: no UI-owned manual refresh sends.

- [ ] **Step 2: Run all directly related regression classes**

Run each class without parallel execution:

```bash
for suite in \
  ReaderRenderRefreshTests \
  ReaderRenderSettingsSnapshotTests \
  ChapterDocumentStoreTests \
  CoreTextScrollTests \
  CoreTextScrollOnlineCacheTests \
  UserFontSettingsTests \
  ChapterTitleAttributedBuilderTests \
  OnlineChapterTitleDeduplicatorTests \
  OnlineReaderPipelineUnificationTests \
  ReaderChapterPresentationTests
do
  xcodebuild test \
    -project Yuedu-Reader.xcodeproj \
    -scheme Yuedu-Reader \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
    -only-testing:"yuedu appTests/$suite" \
    -parallel-testing-enabled NO || exit 1
done
```

Expected: every suite reports `TEST SUCCEEDED`.

- [ ] **Step 3: Run vertical-writing regression when the final diff touches writing-mode settings**

Run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/CoreTextWritingModeTests' \
  -parallel-testing-enabled NO
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 4: Run the application build**

Run:

```bash
xcodebuild \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Review diff and refresh invariants**

Run:

```bash
git diff --check
git status --short
git diff --stat
git diff -- Modules/Core/ReaderCore/EPUBPageRenderer.swift \
  Modules/Core/ReaderCore/ReaderRenderRefresh.swift \
  Modules/Features/Reader/ReaderView+PageBuilding.swift \
  Modules/Features/Reader/ReaderView+OnlineChapterLoading.swift \
  Modules/Features/Reader/CoreTextPagedView.swift \
  Modules/Features/Reader/CoreTextCollectionScrollViewController.swift
```

Confirm:

- `ReaderView` submits intent and never chooses an engine refresh method;
- the renderer assigns every transaction identifier;
- only a visible host acknowledges completion;
- superseded transactions cannot clear manual loading;
- chapter content invalidation occurs once;
- both engines receive the latest settings;
- the stable position remains `(spineIndex, charOffset)`;
- no delay, retry, or alternate cache was added.

- [ ] **Step 6: Commit final cleanup**

```bash
git add -A
git commit -m "refactor: complete reader refresh pipeline"
```
