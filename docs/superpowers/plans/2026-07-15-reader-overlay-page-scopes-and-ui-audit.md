# Reader Overlay Page Scopes and UI Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add separate chapter-opening and chapter-body overlay configurations, stable typography-aware snapping, an Apple-native floating editor, a complete overlay UI design audit, and bilingual battery SVG documentation.

**Architecture:** Keep the version-1 `components` JSON key as the chapter-body compatibility field and add `chapterOpeningComponents` in layout version 2. Runtime and editor code select a `ReaderOverlayPageScope`; a stateful snap session latches independently on X and Y to body-frame boundaries or matching peer alignments. Existing feature views stay in their current files but are normalized to native sheet/list/form conventions and DS tokens.

**Tech Stack:** Swift 6, SwiftUI, CoreGraphics, Swift Testing, existing Yuedu `DS*` tokens and localization system.

---

### Task 1: Add version-2 page scopes and migration

**Files:**
- Modify: `Modules/Core/ReaderCore/Customization/ReaderOverlayLayout.swift`
- Modify: `Modules/Core/ReaderCore/Customization/ReaderOverlayLayoutMigration.swift`
- Modify: `Modules/Core/ReaderCore/Customization/ReaderLayoutPresetImporter.swift`
- Test: `Tests/iOS/yuedu appTests/ReaderOverlayLayoutTests.swift`
- Test: `Tests/iOS/yuedu appTests/ReaderLayoutPresetImporterTests.swift`

- [ ] **Step 1: Write failing migration and round-trip tests**

Add tests that decode a version-1 JSON layout and expect body components to be copied into opening components, then encode/decode a version-2 layout with different arrays and expect both to survive. Add an importer test proving version 2 without `chapterOpeningComponents` is malformed and falls back to explicit legacy fields.

```swift
@Test("version one layouts clone body components into chapter opening")
func versionOneClonesOpeningComponents() throws {
    let data = try JSONEncoder().encode(versionOneFixture)
    let decoded = try JSONDecoder().decode(ReaderOverlayLayout.self, from: data)
    #expect(decoded.components(for: .chapterOpening) == decoded.components(for: .chapterBody))
}

@Test("version two preserves independent page scopes")
func versionTwoPreservesScopes() throws {
    let decoded = try JSONDecoder().decode(
        ReaderOverlayLayout.self,
        from: try JSONEncoder().encode(independentScopeFixture)
    )
    #expect(decoded.components(for: .chapterOpening).map(\.kind) == [.bookTitle])
    #expect(decoded.components(for: .chapterBody).map(\.kind) == [.chapterPage])
}
```

- [ ] **Step 2: Ask the user to run the focused RED tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:'yuedu appTests/ReaderOverlayLayoutTests' \
  -only-testing:'yuedu appTests/ReaderLayoutPresetImporterTests'
```

Expected: failures because `ReaderOverlayPageScope` and opening components do not exist.

- [ ] **Step 3: Implement the scoped layout model**

Add this API while retaining `components` as the body storage key:

```swift
enum ReaderOverlayPageScope: String, CaseIterable, Equatable, Sendable {
    case chapterOpening
    case chapterBody

    static func resolve(chapterPage: Int) -> Self {
        chapterPage == 1 ? .chapterOpening : .chapterBody
    }
}

struct ReaderOverlayLayout: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version: Int
    var components: [ReaderOverlayComponent]
    var chapterOpeningComponents: [ReaderOverlayComponent]
    var contentReservations: ReaderOverlayContentReservations

    func components(for scope: ReaderOverlayPageScope) -> [ReaderOverlayComponent] {
        scope == .chapterOpening ? chapterOpeningComponents : components
    }

    mutating func replaceComponents(
        _ components: [ReaderOverlayComponent],
        for scope: ReaderOverlayPageScope
    ) {
        if scope == .chapterOpening {
            chapterOpeningComponents = components
        } else {
            self.components = components
        }
    }
}
```

Custom decoding copies body into opening when the source version is below 2 or the opening key is absent. Normalization maps both arrays. Migration/default constructors initialize both arrays with value copies. Import validation requires a real opening array when `version >= 2`.

- [ ] **Step 4: Verify GREEN statically and provide the test command**

Run Swift parser checks and `git diff --check`; provide the same focused `xcodebuild` command to the user.

- [ ] **Step 5: Commit Task 1**

```bash
git add Modules/Core/ReaderCore/Customization/ReaderOverlayLayout.swift \
  Modules/Core/ReaderCore/Customization/ReaderOverlayLayoutMigration.swift \
  Modules/Core/ReaderCore/Customization/ReaderLayoutPresetImporter.swift \
  'Tests/iOS/yuedu appTests/ReaderOverlayLayoutTests.swift' \
  'Tests/iOS/yuedu appTests/ReaderLayoutPresetImporterTests.swift'
git commit -m "feat: add scoped reader overlays"
```

### Task 2: Select the correct scope at runtime

**Files:**
- Modify: `Modules/Features/Reader/ReaderOverlayCanvas.swift`
- Modify: `Modules/Features/Reader/ReaderOverlayIntegrationPolicy.swift`
- Modify: `Modules/Features/Reader/ReaderView.swift`
- Test: `Tests/iOS/yuedu appTests/ReaderOverlayIntegrationTests.swift`

- [ ] **Step 1: Write failing scope-selection tests**

```swift
@Test("chapter page one selects opening overlays")
func firstChapterPageUsesOpeningScope() {
    #expect(ReaderOverlayPageScope.resolve(chapterPage: 1) == .chapterOpening)
    #expect(ReaderOverlayPageScope.resolve(chapterPage: 2) == .chapterBody)
    #expect(ReaderOverlayPageScope.resolve(chapterPage: 0) == .chapterBody)
}
```

- [ ] **Step 2: Make canvas scope explicit**

Add `let scope: ReaderOverlayPageScope` to `ReaderOverlayCanvas` and iterate `layout.components(for: scope)`. Runtime passes `ReaderOverlayPageScope.resolve(chapterPage: readerOverlayContentSnapshot.chapterPage)`. The editor passes its active scope. Keep scroll-mode visibility unchanged.

- [ ] **Step 3: Verify and commit**

```bash
git add Modules/Features/Reader/ReaderOverlayCanvas.swift \
  Modules/Features/Reader/ReaderOverlayIntegrationPolicy.swift \
  Modules/Features/Reader/ReaderView.swift \
  'Tests/iOS/yuedu appTests/ReaderOverlayIntegrationTests.swift'
git commit -m "feat: select overlays by chapter page"
```

### Task 3: Replace unstable snapping with axis latches

**Files:**
- Modify: `Modules/Core/ReaderCore/Customization/ReaderOverlaySnapEngine.swift`
- Modify: `Modules/SharedUI/DesignSystem/DesignTokens.swift`
- Modify: `Modules/Features/Reader/ReaderHeaderFooterEditorView.swift`
- Test: `Tests/iOS/yuedu appTests/ReaderOverlaySnapEngineTests.swift`
- Test: `Tests/iOS/yuedu appTests/ReaderOverlayEditorGeometryTests.swift`

- [ ] **Step 1: Replace snap expectations with failing latch tests**

Cover body min/max alignment, peer min/mid/max alignment, absence of canvas/safe-area/standalone-center targets, retaining a latch between 6 and 12 points, releasing beyond 12 points, and independent axes.

```swift
@Test("latched axis does not switch to a closer peer until released")
func latchPreventsOscillation() {
    var session = ReaderOverlaySnapSession()
    let first = resolve(center: CGPoint(x: 105, y: 300), session: &session)
    let retained = resolve(center: CGPoint(x: 110, y: 300), session: &session)
    #expect(first.guides == [.vertical(x: 100)])
    #expect(retained.guides == [.vertical(x: 100)])
}
```

- [ ] **Step 2: Add DS layout tokens**

```swift
static let readerOverlaySnapAcquireDistance: CGFloat = 6
static let readerOverlaySnapReleaseDistance: CGFloat = 12
```

- [ ] **Step 3: Implement stateful snapping**

Create `ReaderOverlaySnapSession` with optional X and Y latches. Generate only these candidates:

- dragged minimum edge to body minimum boundary;
- dragged maximum edge to body maximum boundary;
- dragged minimum/midpoint/maximum to the matching peer line.

Acquire nearest within the acquire token, prefer body boundaries on ties, retain until the release token is exceeded, and return the snapped/clamped center plus active guide lines. Reset the session on drag end. Pass a body frame derived from canvas width, current horizontal page margin, and `contentReservations`.

- [ ] **Step 4: Remove oscillating feedback**

Delete repeated impact feedback and alignment announcements from drag updates. Retain visual guides and accessibility nudge/grid actions.

- [ ] **Step 5: Verify and commit**

```bash
git add Modules/Core/ReaderCore/Customization/ReaderOverlaySnapEngine.swift \
  Modules/SharedUI/DesignSystem/DesignTokens.swift \
  Modules/Features/Reader/ReaderHeaderFooterEditorView.swift \
  'Tests/iOS/yuedu appTests/ReaderOverlaySnapEngineTests.swift' \
  'Tests/iOS/yuedu appTests/ReaderOverlayEditorGeometryTests.swift'
git commit -m "fix: stabilize reader overlay snapping"
```

### Task 4: Make editor operations scope-local

**Files:**
- Modify: `Modules/Features/Reader/ReaderHeaderFooterEditorModel.swift`
- Modify: `Modules/Features/Reader/ReaderHeaderFooterEditorView.swift`
- Modify: `Modules/Features/Reader/ReaderView+HeaderFooterEditor.swift`
- Test: `Tests/iOS/yuedu appTests/ReaderHeaderFooterEditorModelTests.swift`

- [ ] **Step 1: Write failing scope-isolation tests**

Verify add, update, move, delete, undo, and selection affect only the active scope; switching scope clears selection; validation rejects duplicate IDs within one scope but allows the same ID across scopes.

- [ ] **Step 2: Add active scope to the editor model**

```swift
@Published var activeScope: ReaderOverlayPageScope {
    didSet {
        selectedComponentID = nil
        lastDeleted = nil
    }
}

var activeComponents: [ReaderOverlayComponent] {
    draft.components(for: activeScope)
}
```

Each mutation copies `activeComponents`, edits the copy, then calls `draft.replaceComponents(_:for:)`. Store the deletion scope in the undo payload. Initialize the model with the currently visible runtime scope.

- [ ] **Step 3: Verify and commit**

```bash
git add Modules/Features/Reader/ReaderHeaderFooterEditorModel.swift \
  Modules/Features/Reader/ReaderHeaderFooterEditorView.swift \
  Modules/Features/Reader/ReaderView+HeaderFooterEditor.swift \
  'Tests/iOS/yuedu appTests/ReaderHeaderFooterEditorModelTests.swift'
git commit -m "feat: edit opening and body overlays separately"
```

### Task 5: Rebuild the editor chrome and transactional component sheets

**Files:**
- Modify: `Modules/Features/Reader/ReaderHeaderFooterEditorView.swift`
- Modify: `Modules/Features/Reader/ReaderOverlayComponentPickerView.swift`
- Modify: `Modules/Features/Reader/ReaderOverlayComponentEditView.swift`
- Modify: `Modules/Features/Reader/ReaderOverlayFontPickerView.swift`
- Modify: `Modules/SharedUI/DesignSystem/DesignTokens.swift`
- Modify: `Resources/zh-Hant.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Resources/en.lproj/Localizable.strings`
- Test: `Tests/iOS/yuedu appTests/ReaderOverlayComponentEditingTests.swift`

- [ ] **Step 1: Add failing draft-commit tests**

Add a small `ReaderOverlayComponentDraft` value type and test that cancelling returns the original component while confirming returns the normalized draft.

- [ ] **Step 2: Replace editor chrome**

Build one centered material control stack containing:

```swift
Picker(localized("頁面範圍"), selection: $model.activeScope) {
    Text(localized("首頁")).tag(ReaderOverlayPageScope.chapterOpening)
    Text(localized("正文")).tag(ReaderOverlayPageScope.chapterBody)
}
.pickerStyle(.segmented)

Button { presentedSheet = .componentPicker } label: {
    Label(localized("新增組件"), systemImage: "plus")
}

Button { requestExit() } label: {
    Label(localized("退出編輯"), systemImage: "chevron.down")
}
```

Remove the top toolbar and old full-width bottom button. If the draft is unchanged, exit directly. Otherwise present `儲存並退出`, `不儲存退出`, and `繼續編輯` in a native confirmation dialog.

- [ ] **Step 3: Rebuild add/edit sheets using native conventions**

Use an inset-grouped `List` for adding components, with an `xmark` cancellation toolbar item and explicit DS row backgrounds. Change component editing to a local `@State` draft in a modal `NavigationStack`; `xmark` discards and `checkmark` invokes `onSave(draft.normalized)`. Font selection edits only the local draft.

- [ ] **Step 4: Synchronize localization**

Add the new scope and exit-confirmation strings to all three localization files. Replace hard-coded point/percent accessibility formats with localized format keys.

- [ ] **Step 5: Verify and commit**

```bash
ruby scripts/check_localizations.rb
git add Modules/Features/Reader/ReaderHeaderFooterEditorView.swift \
  Modules/Features/Reader/ReaderOverlayComponentPickerView.swift \
  Modules/Features/Reader/ReaderOverlayComponentEditView.swift \
  Modules/Features/Reader/ReaderOverlayFontPickerView.swift \
  Modules/SharedUI/DesignSystem/DesignTokens.swift \
  Resources/zh-Hant.lproj/Localizable.strings \
  Resources/zh-Hans.lproj/Localizable.strings \
  Resources/en.lproj/Localizable.strings \
  'Tests/iOS/yuedu appTests/ReaderOverlayComponentEditingTests.swift'
git commit -m "feat: redesign reader overlay editor"
```

### Task 6: Audit all overlay feature screens against Yuedu iOS design

**Files:**
- Modify: `Modules/Features/Reader/ReaderBatterySVGImportView.swift`
- Modify: `Modules/Features/Reader/ReaderOverlayComponentPickerView.swift`
- Modify: `Modules/Features/Reader/ReaderOverlayComponentEditView.swift`
- Modify: `Modules/Features/Reader/ReaderOverlayFontPickerView.swift`
- Modify: `Modules/Features/Reader/ReaderHeaderFooterEditorView.swift`
- Modify: `Modules/SharedUI/DesignSystem/DesignTokens.swift`
- Modify: all three localization files

- [ ] **Step 1: Run the design checklist file by file**

Check modal title mode, xmark/checkmark semantics, 44-point hit regions, DS-only colors/fonts/spacing/radii/animations, Dynamic Type, Reduce Motion, VoiceOver labels/order, native empty/loading/error states, and explicit themed list row backgrounds.

- [ ] **Step 2: Apply the explicit audit corrections**

- `ReaderBatterySVGImportView`: keep its loading/error/empty behavior, use `.listStyle(.insetGrouped)`, hide the system scroll background, assign `DSColor.surface` to issue/content/import rows in every state, and keep localized labels on `xmark` and `plus`.
- `ReaderOverlayComponentPickerView`: use inset-grouped style, explicit themed row backgrounds, a leading `xmark`, and 44-point component rows.
- `ReaderOverlayComponentEditView`: use a local transactional draft, modal `xmark`/`checkmark`, localized slider values, and explicit form row backgrounds.
- `ReaderOverlayFontPickerView`: keep native navigation, add explicit themed row backgrounds to normal, empty, and missing-font rows, and preserve Dynamic Type fonts.
- `ReaderHeaderFooterEditorView`: use DS tokens for every chrome size/spacing/material boundary, remove fixed visible strings, respect Reduce Motion, and retain 44-point controls.
- Preserve the two already-corrected `DSColor.textSecondary` usages rather than reintroducing a nonexistent tertiary token.

- [ ] **Step 3: Verify and commit**

```bash
ruby scripts/check_localizations.rb
git diff --check
git add Modules/Features/Reader/ReaderBatterySVGImportView.swift \
  Modules/Features/Reader/ReaderOverlayComponentPickerView.swift \
  Modules/Features/Reader/ReaderOverlayComponentEditView.swift \
  Modules/Features/Reader/ReaderOverlayFontPickerView.swift \
  Modules/Features/Reader/ReaderHeaderFooterEditorView.swift \
  Modules/SharedUI/DesignSystem/DesignTokens.swift \
  Resources/zh-Hant.lproj/Localizable.strings \
  Resources/zh-Hans.lproj/Localizable.strings \
  Resources/en.lproj/Localizable.strings
git commit -m "fix: align overlay screens with iOS design"
```

### Task 7: Publish bilingual battery SVG documentation

**Files:**
- Create: `docs/reader-overlay/BatterySVG.zh-Hant.md`
- Create: `docs/reader-overlay/BatterySVG.en.md`
- Reference: `Modules/Core/ReaderCore/Customization/ReaderBatterySVGTemplate.swift`
- Reference: `Tests/iOS/yuedu appTests/ReaderBatterySVGTemplateTests.swift`

- [ ] **Step 1: Extract the production grammar**

Read the parser and tests completely. Record size limits, allowed elements/attributes, color grammar, the two `data-yuedu-role` values, fill directions, visibility behavior, and every rejected external/script/CSS form.

- [ ] **Step 2: Write equivalent Traditional Chinese and English documents**

Include quick start, schema tables, safety restrictions, import workflow, fallback behavior, troubleshooting, and complete horizontal and vertical templates. Every example must pass the actual parser rules.

- [ ] **Step 3: Validate examples and commit**

Add parser fixtures to `ReaderBatterySVGTemplateTests` only if documentation exposes an untested valid example. Provide the user the focused test command.

```bash
git add docs/reader-overlay/BatterySVG.zh-Hant.md \
  docs/reader-overlay/BatterySVG.en.md \
  'Tests/iOS/yuedu appTests/ReaderBatterySVGTemplateTests.swift'
git commit -m "docs: add battery svg template guide"
```

### Task 8: Final verification and dirty-worktree boundary check

**Files:**
- Verify all files changed by Tasks 1-7

- [ ] **Step 1: Parse every touched Swift source**

Run `swiftc -frontend -parse` for the touched production and test Swift files.

- [ ] **Step 2: Validate localizations and documentation**

```bash
ruby scripts/check_localizations.rb
plutil -lint Resources/zh-Hant.lproj/Localizable.strings \
  Resources/zh-Hans.lproj/Localizable.strings \
  Resources/en.lproj/Localizable.strings
git diff --check
```

- [ ] **Step 3: Review persisted-schema and runtime call sites**

Use `rg` to confirm every `ReaderOverlayCanvas` supplies a scope, every layout constructor initializes opening components through the compatible initializer, and no UI file references undefined DS tokens or hard-coded visible strings.

- [ ] **Step 4: Preserve unrelated user changes**

Confirm the staged/cached diffs never include the user's CoreText dialogue work, replacement-menu localization, page-margin range, or other unrelated dirty hunks. Do not use `git add -A`.

- [ ] **Step 5: Provide user-run focused tests**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:'yuedu appTests/ReaderOverlayLayoutTests' \
  -only-testing:'yuedu appTests/ReaderOverlaySnapEngineTests' \
  -only-testing:'yuedu appTests/ReaderHeaderFooterEditorModelTests' \
  -only-testing:'yuedu appTests/ReaderOverlayComponentEditingTests' \
  -only-testing:'yuedu appTests/ReaderOverlayIntegrationTests' \
  -only-testing:'yuedu appTests/ReaderBatterySVGTemplateTests'
```

Per repository instruction, do not run this long `xcodebuild` command automatically.
