---
name: yuedu-tour
description: yuedu iOS EPUB/TXT/web-novel reader codebase orientation. Use before touching reader rendering, CoreText, bookshelf, online reading, book sources, TTS, or localization.
---

# yuedu App Code Tour

All Swift sources live under `Modules/` and `Targets/` (Xcode 16 file-system-synchronized groups — a file dropped into the folder joins the target automatically). Resources (`*.lproj`, assets, entitlements) live under `Resources/`. Tests live in `Tests/iOS/yuedu appTests/`.

## Area Map

| Area | Folders |
|------|---------|
| Reading rendering, layout, paging, scroll | `Modules/Core/ReaderCore/` (+`CoreText/`), `Modules/Features/Reader/` |
| Bookshelf, book CRUD, grouping | `Modules/Services/LibraryStore/`, `Modules/Features/Bookshelf/` |
| Book sources, online reading, rule engine | `Modules/Core/BookSource/`, `Modules/Core/RuleEngine/` (+`ModernParser/`), `Modules/Services/Online/` |
| App entry, DI, global settings | `Targets/Yuedu/SharedApp/` |
| TTS | `Modules/Core/TTS/`, `Modules/Features/Reader/TTS/` |
| RSS | `Modules/Services/RSS/`, `Modules/Features/RSS/` |
| Comics / fixed-layout | `Modules/Core/Comic/`, `Modules/Features/FixedPageReader/` |
| Explore / discover | `Modules/Features/Explore/`, `Modules/Services/Online/DiscoverViewModel.swift` |
| Sync (iCloud/WebDAV), OPDS, LAN | `Modules/Services/iCloud/`, `WebDAV/`, `OPDS/`, `LanServer/` |
| Design system, shared UI | `Modules/SharedUI/` (`DesignSystem/DesignTokens.swift`) |
| iPad shell | `Targets/Yuedu/iPad/`, `Modules/Features/Reader/iPad/` |

## Entry Points

| Need | File |
|------|------|
| App launch, DI | `Targets/Yuedu/SharedApp/yuedu_appApp.swift`, `AppDependencies` |
| Bookshelf | `Modules/Features/Bookshelf/HomeView.swift` |
| Book store | `Modules/Services/LibraryStore/BookStore.swift` |
| Reader screen (mode switch) | `Modules/Features/Reader/BookReaderView.swift` → `ReaderView.swift` |
| Paged view (UIPageViewController) | `Modules/Features/Reader/CoreTextPagedView.swift` |
| Paged engine | `Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift` |
| Paged CoreText layout | `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift` |
| Page rendering (CTFrameDraw) | `Modules/Core/ReaderCore/CoreText/CoreTextPageView.swift` |
| Scroll engine | `Modules/Core/ReaderCore/CoreText/CoreTextScrollEngine.swift` |
| Scroll view controller | `Modules/Features/Reader/CoreTextCollectionScrollViewController.swift` |
| Chunk slicing | `Modules/Core/ReaderCore/CoreText/CoreTextChunkSlicer.swift` |
| Chunk cell rendering | `Modules/Features/Reader/CoreTextChunkCell.swift` (`CoreTextChunkCollectionCell`) |
| HTML → attributed string | `Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift` |
| RenderableNode IR → attributed string | `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift` |
| EPUB CSS resolver | `Modules/Core/ReaderCore/CoreText/EPUBStyleResolver.swift` |
| EPUB page renderer | `Modules/Core/ReaderCore/EPUBPageRenderer.swift` |
| EPUB session (Readium) | `Modules/Core/EPUB/PublicationSession.swift` |
| Page-turn transition FSM | `Modules/Core/ReaderCore/ReaderSessionCoordinator.swift`, `ReaderPageTransitionQueue.swift` |
| Online chapter pipeline | `Modules/Services/Online/OnlineReadingPipeline.swift` |
| Book-source fetch/search | `Modules/Core/BookSource/BookSourceFetcher.swift` |
| Rule engine (Legado rules) | `Modules/Core/RuleEngine/ModernParser/ModernRuleEngine.swift`（工具層：`RuleEngine.swift`） |
| TTS | `Modules/Core/TTS/TTSCoordinator.swift` |
| Settings | `Targets/Yuedu/SharedApp/GlobalSettings.swift` |
| Design tokens | `Modules/SharedUI/DesignSystem/DesignTokens.swift` |

## Search

```bash
ROOT="/Users/zhangruilin/Desktop/Yuedu-reader"
rg -n "YourSymbol" "$ROOT/Modules" "$ROOT/Targets" -g '*.swift'
rg -n '"key"' "$ROOT/Resources/zh-Hant.lproj/Localizable.strings"
```

## Rendering Pipelines

**Paged:** `EPUBPageRenderer` → `CoreTextPageEngine` → `UIPageViewController`（`CoreTextPagedView`）→ `CoreTextPageView`（`CTFrameDraw` 每頁）

**Scroll:** `EPUBPageRenderer` → `CoreTextScrollEngine` → `UICollectionView`（`CoreTextCollectionScrollViewController`）→ `CoreTextChunkCollectionCell`（~2000pt chunks，`CoreTextChunkSlicer` 切分）

**HTML 內容:** EPUB HTML → `HTMLAttributedStringBuilder.buildStyledAST()` → `RenderableNode` IR → `NodeAttributedStringRenderer` → `NSAttributedString`（統一 IR 路徑，2026-06 起）；`HTMLAttributedStringBuilder` 另保留直接 build 供簡單內容。兩者共用 CSS parser、`EPUBStyleResolver`、`ResolvedStyle`/`RenderStyle`。改 CSS 屬性需同步：`ResolvedStyle` + `RenderStyle` + `RenderStyle.from` + 兩條渲染路徑。

**Online:** `BookSourceFetcher.searchBooks()` → `AnalyzeUrl` → `WebFetcher` → `ModernRuleEngine`（CSS/XPath/Regex/JSON）→ `OnlineReadingPipeline` → CoreText。統一入口 `loadWithProvider` → `OnlineProviderAttributedStringBuilder` → `NodeAttributedStringRenderer`。

## CoreText Pitfalls

- **Margin chain**: `ReaderConfig` → `ReaderRenderSettings.contentInsets` → `ChapterLayout` → `CoreTextPageView.draw()`. Don't bypass.
- **Position identity**: Use `(spineIndex, charOffset)`, never `globalPage` as stable identity.
- **`CTFrameGetLineOrigins`**: returns coords relative to path rect, not absolute.
- **`CTLineGetStringIndexForPosition`**: returns nearest char even far outside text bounds. Guard with typographic-width check.
- **Vertical mode**: `ascent`/`descent` = X-axis values, not Y. `paragraphSpacingBefore`/`firstLineHeadIndent` have no inline-direction effect in vertical-rl.
- **Inline images**: `CTFrameDraw` reserves space via CTRunDelegate; must draw images separately via `CoreTextChunkAttachmentExtractor`.
- **Image-only pages**: EPUB covers use `result.imagePage`, not attributed-string CTRunDelegate. Scroll must handle with `isImageOnly` chunk.
- **`prepareAttributedString`**: vertical glyph normalization, font cascade, paragraph defaults. Must be called before pagination AND scroll slicing.
- **Vertical inline annotations**: extracted from CTFrame with `CTRunDelegate` + `inlineAnnotationRunAttribute`; drawn separately from main frame.
- **CJK justification**: `isCJKDominant()` per line; don't justify Latin text without hyphenation.
- **Forbidden CJK punctuation**: use `CJKTypographyProcessor.protectedLineBreakOffset` for page/chunk breaks.

## Writing Mode

- `ReaderWritingMode.verticalRTL` flows through `ReaderRenderSettings` → `PaginationRequest` → `CoreTextPaginator` → `ChapterLayout` → rendering.
- `isVerticalEPUB` detected from EPUB metadata (`session.epubWritingMode`) or CSS `writing-mode: vertical-rl`.
- Scroll axis: vertical EPUB → `.horizontalRTL`; horizontal EPUB → `.vertical`.
- 動直排代碼前先跑 `CoreTextWritingModeTests`。

## Online Reading

- `bookSourceId != nil` → book-source book (rule engine); `nil` → browser-imported.
- `ChapterFetchManager` is an `actor`; generation tokens prevent stale results.
- For browser-imported HTML, preserve semantic blocks; only synthesize `<p>` for true plain-text fallback.
- Inline tags (`<a>`, `<strong>`, `<em>`, `<span>`) must stay inside parent paragraphs.
- 驗證規則引擎修復時務必用**全新沒開過的書**測試 — 快取的 bookInfo/tocUrl/目錄會遮蔽修復效果。

## Localization

所有 UI 文字必須透過 `localized()` 包裹，禁止直接寫死字串：

```swift
// ✅ 正確
Text(localized("選取"))
Button(localized("新增 RSS 訂閱"))

// ❌ 錯誤 — 直接寫死字串
Text("選取")
Text("RSS Source")
```

### 新增 UI 文字的規則

1. 用 `localized("key")` 包裹，key 本身用繁體中文
2. 同步更新三個 lproj 檔案（位於 `Resources/`），缺一不可：
   - `Resources/zh-Hant.lproj/Localizable.strings` — key = value（繁體）
   - `Resources/zh-Hans.lproj/Localizable.strings` — value 為簡體中文
   - `Resources/en.lproj/Localizable.strings` — value 為英文
3. 新增 key 前先確認該 key 是否已存在於三個檔案中
4. RSS/feed 相關的 "訂閱" 概念在英文檔映射為 "Feed"（如 "RSS 訂閱" → "RSS Subscriptions"、"訂閱源" → "Feed"）

### 驗證

```bash
ROOT="/Users/zhangruilin/Desktop/Yuedu-reader/Resources"
for lproj in zh-Hant zh-Hans en; do
  grep -F '"你的 key"' "$ROOT/$lproj.lproj/Localizable.strings" || echo "缺少: $lproj"
done
```

## Extension Points

| Add | Use |
|-----|-----|
| New file format | `BookParser` + `BookParserRegistry`（`BookParsing.swift`，rg 可尋） |
| New chapter source | `BookContentProvider` |
| New attributed-string source | `AttributedStringBuilding` |
| New CSS property | `HTMLCSSPropertyApplier` in `CSSPropertyApplier.swift`（＋同步 `ResolvedStyle`/`RenderStyle`） |
| New TTS engine | `TTSPlayable` |
| New global service | Define protocol → `AppDependencies` → `@Environment` |

## Build

```bash
cd "/Users/zhangruilin/Desktop/Yuedu-reader"
xcodebuild -project "Yuedu-Reader.xcodeproj" -scheme "Yuedu-Reader" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -configuration Debug build
```

注意：在 Claude session 內不要直接跑 xcodebuild（會卡住數分鐘）——改法交給使用者在 Xcode build 驗證，或用 `run-yuedu-reader` skill 的 driver。

## Deeper Docs

- `Technotes/Architecture.md` — 全架構
- `docs/coretext/README.md`、`docs/coretext/rendering-pipeline.md`、`docs/coretext/vertical-writing.md`
- `docs/design.md` — UI 規範（配合 `yuedu-ios-design` skill）
