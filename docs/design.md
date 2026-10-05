# Yuedu Reader — iOS 原生設計規範 (design.md)

> 本檔是 Yuedu Reader（閱讀）所有 UI 設計與實作必須遵守的單一準則。
> 目標：做出「**成熟的大型 iOS 原生閱讀器**」，而不是網頁後台、Landing Page、Dashboard 或 Android App。
> 實作入口見 `.claude/skills/yuedu-ios-design/SKILL.md` 與 `.agents/skills/yuedu-ios-design/SKILL.md`；兩份 skill 必須同步維護，規則以本檔為準。

合成來源（依優先序）：
1. **Apple Human Interface Guidelines / Apple 平台文件** — 平台行為與元件的最高權威。
2. **Yuedu 專案規範與既有設計系統** — 在不違反 Apple 規範下維持產品一致性。
3. **通用可用性建議** — 例如 Nielsen 啟發法，作為設計檢查而非平台行為依據。

### 規則權威層級

- **[Apple]**：Apple HIG、Accessibility、SwiftUI API 與官方設計資源；若規則衝突，以此層為準。
- **[Yuedu]**：本專案的產品決策、元件慣例與 `DS*` token；僅能在 Apple 允許的範圍內加嚴或具體化。
- **[建議]**：Nielsen 等通用可用性原則與設計經驗；不能覆蓋 [Apple] 或 [Yuedu]。

優先序為 **[Apple] > [Yuedu] > [建議]**。下文未標示時，硬規則視為 [Yuedu]；涉及系統元件語意與行為時仍以 [Apple] 為準。

---

## 0. 最高原則

1. 一切以 **Apple HIG** 為準；不確定時選「最像系統內建 App」的做法。
2. **閱讀體驗 > 視覺花俏**。任何裝飾不得傷害正文可讀性。
3. **原生元件優先**。先問「系統內建 App 會怎麼做」，再動手。
4. 每個畫面都必須支援 **深色模式、Dynamic Type、VoiceOver、單手操作**。
5. **不要重造系統能力**：能用 `List`/`Sheet`/`Menu`/`Toolbar` 就不要自刻。

---

## 1. 不可違反的硬規則（Hard Rules）

這些是 PR review 會直接擋下的紅線：

| # | 規則 | 正確 | 錯誤 |
|---|------|------|------|
| H1 | title mode：僅主界面根目錄（Tab 根頁）用大標題，一律經 `rootTabTitle(_:onScroll:)`；其餘一律 `.inline` | 見 §2 矩陣 | 在 pushed / sheet 用 `rootTabTitle(_:onScroll:)`，或使用 `.automatic` / `.large` / `.inlineLarge` |
| H2 | 所有對使用者顯示的文字走 `localized("…")`，且每個 lproj 同步（目前為 zh-Hant、zh-Hans、en、ja、ko，含 `InfoPlist.strings` 的權限提示） | `Text(localized("書架"))` | `Text("Bookshelf")` |
| H3 | 顏色、字級、間距、圓角、動畫一律用 `DS*` token | `DSColor.textSecondary` | `Color.gray` / 寫死 hex |
| H4 | 圖示優先 SF Symbols，且與文字字重/字級一致 | `Image(systemName: "trash")` | 自製 PNG icon |
| H5 | icon-only 按鈕必須有 `accessibilityLabel` | `.accessibilityLabel(localized("刪除"))` | 只有圖示無語意 |
| H6 | 顏色不得作為唯一狀態提示（需文字/圖示輔助） | 「失敗」紅字+`xmark` | 只靠紅色 |
| H7 | 一般互動的 **hit region** 預設至少 **44×44pt**；**28×28pt** 只描述受限 compact 情境的最小 visible control size，必須搭配充分 spacing，不能當作縮小一般 hit target 的理由；reader chrome 與 primary actions 維持至少 44×44pt hit region | 擴大 hit region 且控制間保留間距 | 把 28pt visible control 直接當一般 hit target |
| H8 | 每個資料畫面都要設計 **空 / 載入 / 錯誤** 三態 | 見 §9 | 只做 happy path |
| H9 | 不得做成網頁式 UI（dashboard 卡片牆、側欄、Landing） | 見 §13 | Tailwind 風格 |
| H10 | accessibility modifier 只能加在**該元素本身**，不能加在容器上（會往下傳給每個子元素） | 每顆 `Button` 各自 `.accessibilityLabel` | 在包住三顆按鈕的 `HStack` 上加一個 label |
| H11 | 區塊底部說明一律收攏為原生 `Section { ... } footer: { Text(...) }` 並套用 `.dsSectionFooter()`（Apple HIG 13pt Footnote + `DSColor.textSecondary`） | `Section { ... } footer: { Text(localized("...")).dsSectionFooter() }` | 在 Section 內用普通 Row 當說明、用 `VStack` 塞副標題、或單獨開說明 Section |
| H11b | footer 只寫控制項看不出來的事（代價／風險／副作用／資料來源），一句話，最多兩句 | 「刪除帳號無法復原。」 | 複述按鈕標籤（「重新整理名單」配上一段解釋它會重新整理名單）、描述實作、解釋功能存在的理由 |

---

## 2. 頁面標題、Toolbar 與 Sheet

### 2.1 標題模式矩陣

先判斷畫面是否為「主界面根目錄」（Tab 根頁）；規則只有兩種狀態，toolbar 是否存在不是決定條件。

| 情境 | title mode | 原因 / 注意事項 |
|------|------------|-----------------|
| **主界面根目錄**（Tab 根頁） | `rootTabTitle(_:onScroll:)` | 唯一用大標題的層級：導覽列左側的粗體大標題，和右側按鈕同一行，iOS 17 起每個版本都一樣。 |
| Pushed detail（導航堆疊內的詳情、設定子頁） | `.inline` | 維持清楚的返回層級，為導覽與動作保留空間。 |
| Sheet / modal task | `.inline` | 標題精簡，leading / trailing 分別容納取消與完成。 |
| Reader / immersive surface | `.inline` | 依沉浸狀態與 chrome 顯示需求決定呈現；不使用大標題。 |

**主界面根目錄白名單**：書架 `HomeView`、探索 `ExploreHomeView`、RSS `RSSListView`、設定 `SettingsView`、搜索 tab 根頁（`SearchView(isTabRoot: true)`；同一頁被推入時仍是 `.inline`）。名單以外的頁面一律 `.inline`。

大標題是主界面根目錄的固定樣式（Apple Music / App Store 式的大型標題、同時保留完整 toolbar），**不是全域預設**：根目錄以外任何層級都禁用。不用系統的 `.inlineLarge`：它在 iOS 17 的 iPhone 上只畫成置中的 `.inline` 小標題（iOS 17.5 模擬器實測），iOS 18 起才是大標題。`rootTabTitle(_:onScroll:)` 改用自己的 `.topBarLeading` toolbar item 畫標題（iOS 26 起關掉它的玻璃底），系統標題藏起來但仍設定，推入頁的返回鍵照樣顯示「‹ 探索」；字級固定在預設大小（系統的列內大標題也不隨字級放大，iOS 27 實測），長按顯示大型內容檢視器，VoiceOver 讀成標題。根頁的 leading item 會排在大標題右邊，加之前要驗證可用寬度與本地化。捲動行為分兩種，都是原生導覽列、原生 toolbar、原生 `.searchable`。書架用 `rootTabTitle(_:onScroll: .fadesTitle)`：頁面在捲動內容裡放 `rootTabTitleScrollAnchor()`（內容堆疊、格狀、列表第一列，沒得捲的空狀態也放），往下捲 10pt 起標題淡出、再 30pt 完全消失，右側按鈕常駐，不管怎麼回到頂端標題都會回來。探索、RSS、設定、搜索用 `.minimizesBar`，即 iOS 27 的導覽列縮起（`toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)`，WWDC26〈Modernize your UIKit app〉）：往下捲，整條導覽列──標題和按鈕一起──滑走，`.navigationBarDrawer(displayMode: .always)` 的搜尋框升到狀態列下方；往上捲再回來（Apple Music 的分頁，iOS 27 模擬器實測）。探索、搜索的捲動視圖用 `rootTabSearchScrollEdges()` 取代 `softScrollEdges()`：iOS 27 用系統自己的邊緣，導覽列在時是柔和的，搜尋框升上去後它正下方的內容清楚（Apple Music 也是）；強制 `.soft` 會把那段內容糊掉。RSS、設定沒有搜尋框，系統邊緣會變成硬邊，所以維持 `softScrollEdges()`（以上都是 iOS 27 模擬器實測；Apple 也請導覽列會縮起的 app 重新評估 `.soft` 覆寫）。內容不到一屏多時系統不縮起導覽列。iOS 17–26 沒有導覽列縮起：`.minimizesBar` 退回標題淡出，按鈕和搜尋框留在原位，所以這幾頁也放 scroll anchor。不要把標題列或搜尋框畫進頁面：自製的搜尋框和按鈕不是原生的（使用者否決）。系統標題模式也做不到：`.inlineLarge` 捲動後縮成置中小標題、搜尋框留在原位；`.large` 配常駐搜尋框一開始就是小標題（iOS 27 實測）。不用 UIKit `hidesBarsOnSwipe`：捲回頂端時導覽列不會自己回來（使用者回報），搜尋框也跟著藏起來。

### 2.2 Toolbar 動作位置與語意

- 主要頁面動作放在 trailing（通常是 `.topBarTrailing`）；返回由導航容器提供，避免自行複製。
- Sheet 的 **Cancel / Close** 放 leading：立即關閉且不儲存未確認的變更。
- Sheet 的 **Done** 放 trailing：完成流程，並在有編輯內容時儲存或提交。
- **Back** 只用於 sheet 內部多步導航，不代表取消或完成。
- 同一層級不要同時呈現 Back、Cancel / Close、Done 三者；先釐清當前步驟的退出與提交語意。
- [Yuedu] 可見的 modal / toolbar chrome 使用 `xmark` 與 `checkmark`，並提供 `localized(...)` 的 `accessibilityLabel`。系統 alert / confirmation dialog 中 `role: .cancel` 的動作保留文字，維持清楚語意。
- Toolbar 圖示優先跟隨相鄰 semantic text style 或系統控制 sizing；`DSFont.toolbarIcon` / `DSFont.toolbarIconLarge` 是固定尺寸例外，只能用於不承載文字的 chrome，且必須以最大 Dynamic Type 驗證。顏色使用 `DSColor.accent` 或 `DSColor.textSecondary`。

```swift
// Pushed detail
BookDetailView()
    .navigationTitle(localized("書籍詳情"))
    .toolbarTitleDisplayMode(.inline)

// Editable sheet
EditSourceView()
    .navigationTitle(localized("編輯書源"))
    .toolbarTitleDisplayMode(.inline)
    .toolbar {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(localized("取消"))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button { saveAndDismiss() } label: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel(localized("完成"))
        }
    }
```

---

## 3. 設計系統 Token（綁定 `Modules/SharedUI/DesignSystem/DesignTokens.swift`）

**禁止寫死顏色 / 字體 / 間距 / 圓角 / 動畫時間。** 一律引用 token；缺的 token 先補進 `DesignTokens.swift` 再用。

### 顏色 `DSColor`
| 用途 | Token |
|------|-------|
| 主色（按鈕、連結、選取） | `accent` |
| 成功 / 警告 / 破壞性 | `success` / `warning` / `destructive` |
| 主文字 / 次文字 / 停用 | `textPrimary` / `textSecondary` / `textDisabled` |
| 頁背景 / 卡片 / 巢狀 / 分組背景 | `background` / `surface` / `surfaceTertiary` / `groupedBackground` |
| 分隔線 / 邊框 | `separator` / `border` |
| 選取高亮 / 淺底 / 陰影 | `highlight` / `accentLight` / `shadow` |
| 書封漸層 | `coverGradients` |

> `text*`、`background`、`surface*`、`separator` 等 system-backed tokens 會隨系統 appearance 適應。`accentLight`、`highlight`、`shadow`、`coverGradients` 與任何 brand RGB 並非因此自動 adaptive；必須逐一在 Light、Dark 與 Increase Contrast 驗證，必要時先新增對應的 adaptive token。不要在使用端直接寫 `Color.gray`、`Color(hex:)` 或品牌硬色。

### 字體 `DSFont`
`caption2 / caption / subheadline / body / bodyBold / headline / title2 / title / largeTitle`，等寬 `monospaced(size:)`，toolbar `toolbarIcon / toolbarIconLarge`。
- `caption2` 至 `largeTitle` 等 semantic tokens 支援 Dynamic Type；`monospaced(size:)`、`toolbarIcon`、`toolbarIconLarge` 是固定 size 例外，不會自動取得同等縮放行為。
- User-visible text 不得使用固定 size token。若內容必須採 custom 或 monospaced 字體，先新增相對於 semantic text style 的 token，再驗證最大 accessibility size 與 Bold Text。
- Toolbar icon 優先跟隨相鄰 semantic text style 或 system sizing；使用固定 icon token 時，必須確認放大字級下不會失衡、遮擋或縮小 hit region。

### 間距 `DSSpacing`
`xs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32`。頁面外距用 `xl`，群組間 `lg`，元素內 `sm`。

### 圓角 `DSRadius`
`sm=6（標籤/小按鈕） / md=8（按鈕/輸入框） / lg=12（卡片/對話框） / xl=16（圖片容器）`。

### 動畫 `DSAnimation`
`fast=0.15（即時回饋） / standard=0.28（轉場） / slow=0.4（展開）`。不要硬寫 duration。

專用 token：`readerChrome`（閱讀選單顯示／隱藏，以及跟著它動的元件；`showBars` 一律經 `setReaderChromeVisible(_:)` 寫入）、`press`（按壓回彈）、`dragSettle`（拖曳放手後回到界內）、`splashFade`（啟動圖淡出）。開書卡片轉場的時長 `readerBookTransitionDuration`（0.62s）是定案，不要因為「超過 300ms」去改短。

`DSAnimation` 只是時序 token，不會自行讀取 Reduce Motion；每個含位移、縮放或連續運動的 view 都必須依環境值切換動畫策略。

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

private func updateExpandedState() {
    withAnimation(reduceMotion ? nil : DSAnimation.standard) {
        isExpanded.toggle()
    }
}
```

Reduce Motion 開啟時，移除非必要位移與縮放；需要保留狀態轉換提示時，改用 opacity 或無動畫的即時結果。

---

## 3.1 iPad / 自適應佈局

iPad 是同一個 iOS app 的原生自適應版，不是另一個 app root。共享資料模型與 reader engine 在 `Modules/Core` / `Modules/Services`，feature UI 與設定在 `Modules/Features`，design token 在 `Modules/SharedUI/DesignSystem`；iPad 專屬 shell 放 `Targets/Yuedu/iPad/`、iPad reader UI 放 `Modules/Features/Reader/iPad/` 等明確目錄，避免散落機型判斷。

- 佈局用 size class、scene/window size 與 readable width 驅動；不要散落 `UIDevice.model` 或機型字串判斷。
- 內容必須尊重 safe areas 與 system margins；除非是刻意的沉浸式背景，不要用負間距或硬編碼 inset 蓋過系統區域。
- 以實際 window size 自適應，不以裝置名稱推測空間；多工、Stage Manager、Split View 與旋轉都可能改變可用尺寸。
- 延後切換到 compact 版型，直到目前版型真的無法維持可讀性與操作間距；不要只因單一 size class 或任意 breakpoint 過早縮減資訊。
- iPhone 維持 compact/portrait 的底部 Tab Bar；iPad regular 使用系統 `TabView.sidebarAdaptable` 或 `NavigationSplitView` 等 HIG 原生容器，不自刻側欄。
- 底部 Tab Bar 只在分頁根頁顯示（產品決定，2026-10-03；2026-10-05 釐清）：根頁以外的任何頁面，只要有一部分疊到 Tab Bar 的位置就收起——push、sheet、全螢幕、popover（iPhone 上 popover 通常就以 sheet 呈現）；沒疊到就不收，例如 iOS 17 iPad 寬視窗裡浮在中間的 sheet 卡片；menu（例如根頁 toolbar 按鈕打開的選單）、alert、確認對話框、搜尋框不是頁面，不收。根頁就是用 `rootTabTitle(_:onScroll:)` 的那五頁（它帶 `showsRootTabBarOnlyHere()`，見 `RootTabBarVisibility`），推進去的頁面不必自己藏。iPad regular 的頂部分頁列不受這條影響。
- iPad 橫豎向與視窗 resize 都要能重排；需要 reader 重分頁時，以 SwiftUI 已量到的 viewport size 作為唯一觸發來源。
- 寬螢幕設定頁、sheet、清單與 reader overlay 使用 `DSLayout.readable*Width` token 限制行長；不要直接寫 640/760/960 等 magic number。
- 閱讀器橫向雙頁是 reader 專屬模式：iPad regular + landscape 才自動啟用；切回直向或 iPhone 時回單頁，閱讀位置以 `(spineIndex, charOffset)` 保持。
- iPad 專屬檔案可以包裝共享 view，但不得複製業務邏輯；狀態、同步、書源、閱讀進度仍由共享 model / coordinator 負責。
- 自適應驗收至少涵蓋：不同 window size、橫直向、本地化長字串，以及最大 Dynamic Type / accessibility size。

---

## 4. iOS 原生元件選型

| 需求 | 用 | 不要用 |
|------|-----|--------|
| 頁面導航 | `NavigationStack` + `navigationDestination` | 自刻 push 動畫 |
| 主分頁 | `TabView`（底部 Tab Bar） | 自刻底部列 / 側欄 |
| 清單 / 設定 | `List`（`.plain` 或 `.insetGrouped`）+ `Section` + `ForEach` row | `ScrollView`+`VStack`/`HStack` 手刻 row、網頁表單 |
| 設定行內容 | `Toggle` / `Picker` / `Stepper` / `NavigationLink` / `Slider` | 自刻開關、自刻下拉 |
| 短流程 / 次要任務 | `.sheet`（可加 `.presentationDetents`） | 全螢幕擋住 |
| 重任務 / 沉浸（閱讀器） | `.fullScreenCover` | sheet 硬塞 |
| 就地選擇 | `Menu` / `Picker` | 自刻下拉 |
| 工具列 / 頁面動作 | `.toolbar { ToolbarItem }` | 自刻按鈕列、`ZStack` overlay 偽工具列 |
| 長按操作 | `.contextMenu` | 自刻浮層 |
| 列項滑動操作 | `.swipeActions` | 自刻手勢 |
| 破壞性確認 | `.confirmationDialog` / `.alert` | 自刻彈窗 |
| 搜尋 | `.searchable` 或既有 `DSSearchBar` | 網頁式 search box |
| 載入 | `ProgressView` | 自刻 spinner |

設定頁一律 **iOS Settings 風格**（`Form` / `List` `.insetGrouped` 分組 + section header），不要做成網頁表單。

**設定列一律用 `SettingsRows`**（`Modules/SharedUI/Components/SettingsRows.swift`）：`SettingsRowLabel`（圖示＋標題，與「設定」主頁 `DSSettingsRow` 同一個 `IconConsistentLabelStyle`）、`SettingsValueLabel`（推頁列＋右側目前值）、`SettingsSliderRow`（標題與值一行、滑桿在下）、`SettingsLockedRow`（Pro 鎖定列）。原生控制項照用，只把 label 換成這些，同一頁的每一列才會是同一個圖示大小、顏色與對齊。

- 同一頁要嘛每列都有圖示，要嘛都沒有；同一個設定在不同頁（例如閱讀設定與排版生效範圍）用同一個 SF Symbol。
- 列圖示避開 SF Symbols 會換成在地化字形的符號：`textformat` 在中文會變成「格式」兩個字、`textformat.size`、`character.textbox` 等同理（CoreGlyphs 裡有 `.zh` 變體的都是）。`a.magnify` 也會把 a 換成「字」。字體用 `f.cursive`、字級用 `plus.magnifyingglass`。
- 列的角色：一般設定 `.standard`；點了就執行的動作（匯出、匯入、重設單一值）`.action`；會覆蓋使用者一組設定或刪除東西的 `.destructive`，並先用 alert 確認。
- 推進去的頁面標題要和列名相同（列叫「段評氣泡」，頁就叫「段評氣泡」）。
- 繁中用語（2026-09-28 統一）：匯入／匯出（不用導入／導出）、自訂（不用自定義）、介面（不用界面）、儲存（不用保存）、重設（不用重置／還原）、閱讀背景（不用閱讀主題）、頁首頁尾（不用頁眉頁腳）、全域（不用全局；既有功能名如「全局翻頁」照舊，不自行改名）。改既有字串時**只改 zh-Hant 的值、不改 key**（例：「全局默認」＝「全域預設」），其他語系的值照各自慣例。

### 4.1 主題背景與 List/Form 背景連續性

- `.scrollContentBackground(.hidden)` 只會隱藏 `List` / `Form` 的捲動容器背景，**不會自動清除每個 row / section 的系統背景**。如果外層已繪製 `PageBackgroundView`、`themedAppSurface` 或其他主題背景，保留預設 row 背景會形成上方有色、下方純白等意外色塊斷裂。
- 頁面背景應連續透出時，所有內容列、section、空狀態、載入狀態與錯誤狀態都必須明確使用 `.listRowBackground(Color.clear)`；不能只處理正常資料列。
- 若產品刻意讓 row 與頁面背景形成層級，必須明確使用 `DSColor.surface` / `DSColor.surfaceTertiary` 等語意 token。禁止依賴未指定的系統白色或只在目前 Light Mode 看起來剛好一致。
- Review 時必須同時檢查 navigation bar、固定摘要區、scroll content 與所有 row 的背景是否屬於同一套語意層級，並在 Light、Dark、自訂主題與頁面背景圖片下驗證。

```swift
List(items) { item in
    ItemRow(item: item)
        .listRowBackground(Color.clear) // 讓 PageBackgroundView 連續透出
}
.scrollContentBackground(.hidden)
.background(PageBackgroundView(scope: .settings))
```

若 row 應為卡片層級，則改用明確語意色：

```swift
ItemRow(item: item)
    .listRowBackground(DSColor.surface)
```

Review 時同時檢視 surface 層級是否「從背景中看得出」：容器色必須明顯區分於頁背景與兄弟容器，幾乎同色的容器等於沒有層級（曾發生審查沒抓到、bubble 與背景同色的真實案例）。

### 4.2 區塊底部說明（Section Footer）規範

- **統一原生 footer**：所有針對 Section 或整組設定的提示、說明、限制條件，一律使用原生 `Section { ... } footer: { Text(...) }`。
- **嚴禁自刻說明列**：嚴禁在 Section 內部使用普通 Row 放說明文字（會變成卡片 row 外觀與過大行高）、嚴禁在 Toggle 的 label `VStack` 內手動塞說明文字充當區塊附註、嚴禁單獨開一個沒有內容的 Section 專門放說明 Text。
- **統一字級與顏色**：Apple HIG 規範 Section footer 為 **13pt Footnote** 與 **次要顏色（`DSColor.textSecondary`）**。因為最外層環境可能注入全域字體，為避免字級被放大成 17pt 正文，所有 footer 內的 `Text` 一律呼叫 `.dsSectionFooter()`（錯誤/警示訊息傳入 `.dsSectionFooter(color: DSColor.destructive)`）。
- **寫得出理由才寫 footer**：footer 只寫控制項本身看不出來的事——代價、風險、副作用、不明顯的前提，或這份資料從哪來。**標籤已經講完的就不要再寫一次**：「重新整理名單」不需要一段說明它會重新整理名單。
- **長度上限一句，最多兩句**：不要複述按鈕、不要描述實作、不要解釋這個功能為什麼存在。動手前先問「不寫這句，使用者會誤會什麼？」——答案是「不會」就刪掉。

```swift
Section {
    Toggle(localized("自動同步"), isOn: $gs.iCloudAutoSync)
} footer: {
    Text(localized("開啟後，App 啟動與切到背景時會自動與 iCloud 合併同步。"))
        .dsSectionFooter()
}
.interfaceSectionSurface()
```

---

## 5. 排版與字級

- 用語義 text styles 表達層級：`largeTitle` / `title` 標題 → `headline` 區塊標題 → `body` 正文 → `subheadline` / `caption` 輔助；不要用固定 pt 模擬層級。
- **支援 Dynamic Type 到最大 accessibility size**：優先讓內容換行與容器增高，不以截斷掩蓋關鍵文字。
- 大字級時將 metadata（作者、來源、時間、狀態）改為垂直 stacking；grid 逐步減欄，必要時降為單欄，避免壓縮文字與點擊區。
- 自訂字體必須以語義 metrics 縮放，並在 **Bold Text** 開啟時維持可辨識的粗細差異；沒有原生粗體字面時提供經驗證的 fallback。
- SF Symbols 跟隨相鄰語義字級與 Dynamic Type scaling，不用固定 frame 鎖死圖示；固定尺寸的 toolbar icon 是需單獨驗證的例外，不代表自動支援 Dynamic Type。
- 三行以上的文字避免 tight leading；正文與說明文字需保留足以掃讀的行距。
- 對齊與留白勝過分隔線；分隔線只在 `List` 語義需要時出現。
- 字級數量克制：同一畫面維持 ≤5 種不同字級，層級靠字重與字軸建立，不是堆疊更多尺寸；`tracking` 最多 2 種值且只用於大寫標籤。
- 需要字體對比時優先使用 SF 字軸（`.fontDesign(.serif)` / `.rounded` / `.monospaced`）建立層次（如標題用 serif、數值用 monospaced），不要為此引入自訂字體；自訂字體仍必須以語義 metrics 縮放。
- 不要用 `minimumScaleFactor` 硬縮文字救版面；讓容器重排或換行。

---

## 6. SF Symbols / 視覺一致性

- 圖示**優先 SF Symbols**；字重、尺寸、語意與相鄰文字一致（同一列圖示風格統一，不混 fill / outline）。
- 不自創不必要的 icon style；功能性圖示服務「閱讀、選書、搜尋、設定」，不裝飾。
- 用 system colors 與 `DSColor`，不硬寫網頁品牌色（搜尋引擎 brand 色已有專屬 token）。
- 書封缺圖用 `DSColor.coverGradients` 生成漸層佔位，不要空白方塊。

---

## 7. 無障礙 Accessibility（閱讀器必做）

每個畫面都要過這份清單：
- [ ] 正文、設定項、按鈕文字支援 **Dynamic Type** 到最大 accessibility size，內容仍可讀、可操作。
- [ ] 所有 **icon-only 按鈕** 有 `accessibilityLabel`（用 `localized`）。
- [ ] 一般互動的 **hit region** 至少 **44×44pt**。受限 compact 情境可讓 **visible control** 最小為 **28×28pt**，但需以 padding / frame 擴大版面並用 `contentShape` 定義完整可點區域，同時在相鄰 controls 間保留充分 spacing；28pt 不是一般 hit-target 例外，reader chrome 與 primary actions 仍維持至少 44×44pt。
- [ ] 狀態與錯誤不是 color-only：顏色之外另有文字、圖示、形狀或位置提示。
- [ ] Light / Dark Mode 與 **Increase Contrast** 下皆可辨識；不要以低對比透明疊色承載必要資訊。
- [ ] **Reduce Motion** 開啟時停用非必要位移、縮放與連續動畫，改用 opacity 或無動畫結果；實作用 `@Environment(\.accessibilityReduceMotion)` 選擇動畫，不能只套 `DSAnimation` token。
- [ ] VoiceOver 能依合理 order 朗讀標題、內容與動作，並在儲存、刪除、載入或錯誤後說明 outcome；必要時用 announcement 或 focus 管理。
- [ ] 閱讀頁避免動畫、透明、背景紋理干擾文字辨識。
- [ ] 純裝飾元素使用 `.accessibilityHidden(true)`；同一語意的標題、metadata 與狀態適當 grouping（例如 `.accessibilityElement(children: .combine)`），但不要合併需要獨立操作的控制。

### 7.1 SwiftUI 已經踩過的三個坑

這三個不是理論風險，都是實際出貨後由使用者回報的 VoiceOver bug（TTS 迷你播放器與語速滑桿）：

- **accessibility modifier 加在容器上會往下傳。** 套在 `HStack` / `VStack` 上的 `.accessibilityLabel`、`.accessibilityHint` 會傳給底下**每一個**子元素。迷你播放器因此把封面、播放/暫停、關閉三顆按鈕全部命名成書名，旁白連念三次同一個名字。→ 標在各自的 `Button` 上（見 H10）。
- **`Image(systemName:)` 預設就是可聚焦元素。** SF Symbol 自帶名稱，旁白會念出「speedometer」這種符號名。裝飾用的圖示（滑桿兩端的慢/快圖示、列尾自繪的 `chevron.right`）一律 `.accessibilityHidden(true)`。
  **只在 `Button` 上加 `.accessibilityLabel` 不夠。** 閱讀器經典底欄的換源鈕就是 `Button { Image(systemName: "arrow.left.and.right") } .accessibilityLabel(localized("換源"))`，旁白仍念「arrow.left.and.right」——符號在按鈕旁自成一個元素，把按鈕的名字蓋掉了。**icon-only 按鈕要兩件事一起做**：圖示 `.accessibilityHidden(true)` ＋ 按鈕 `.accessibilityLabel`。改用 `Label(text, systemImage:).labelStyle(.iconOnly)` 也可以，它念的是 text 不是符號名。
- **`Slider` 不會自己有語意。** 預設 label 是空的、value 是「相對於 range 的百分比」，跟畫面上顯示的數值對不上（語速 range 是 0.1–2.5，畫面卻顯示 `rate / 0.5 * 100`%）。務必自己給 `.accessibilityLabel` 與 `.accessibilityValue`，且 value 與畫面上那行說明文字**共用同一個計算屬性**，不要各算各的。

```swift
HStack {
    Image(systemName: "tortoise")
        .accessibilityHidden(true)          // 裝飾用，不進 VoiceOver
    Slider(value: $rate, in: 0.1...2.5, step: 0.05)
        .accessibilityLabel(localized("語速"))
        .accessibilityValue(speechRateText) // 與下方說明文字同一來源
    Image(systemName: "hare")
        .accessibilityHidden(true)
}
Text("\(localized("當前速度"))：\(speechRateText)")
```

---

## 8. 可用性（Nielsen 十大啟發）

每個頁面自問：
- **系統狀態可見**：使用者知道現在在哪、在載入/成功/失敗嗎？
- **貼近真實世界**：用「書架/書源/章節/訂閱」這類使用者語言，不用技術黑話。
- **使用者掌控**：返回、取消、復原清楚可達。
- **一致性**：同類操作在全 App 位置/命名/圖示一致。
- **錯誤預防**：破壞性操作前確認；輸入即時驗證。
- **辨識勝於記憶**：選項可見，不要逼使用者記指令。
- **彈性效率**：常用操作有捷徑（swipe、長按、Menu）。
- **美學與簡約**：一頁不塞太多資訊/按鈕/層級。
- **錯誤可復原**：錯誤訊息說明「發生什麼 + 怎麼修」。
- **說明文件**：必要處提供輕量提示，不喧賓奪主。

補充準則（跨框架通用，源於外部 skill 審計，詳見參考章節）：
- **權限請求**：在功能發生的當下才請求權限，絕不在啟動時一起問；系統對話框前先用說明畫面解釋原因與用途；被拒後提供前往系統設定的路徑，並設計被拒後的降級體驗。
- **回饋強度匹配**：`alert` / `confirmationDialog` 只用於需要使用者決定的關鍵時刻（2 鍵為佳，最多 3 鍵）；非關鍵提示用 inline 提示、banner 或狀態列呈現，不要用 alert 打斷。
- **手勢有替代**：任何自訂手勢（滑動、長按、雙擊）必須同時有可見的按鈕或選單入口；系統手勢（左緣返回、下拉通知/控制中心）不得攔截。
- **觸覺與數字回饋**：重要動作（儲存、刪除、完成、狀態翻轉）給 `.sensoryFeedback`；變動中的數字用 `.contentTransition(.numericText())` 呈現；兩者皆遵守 Reduce Motion。

---

## 9. 狀態設計（每頁必備三態）

| 狀態 | 必含 | 範例 |
|------|------|------|
| **空狀態 Empty** | 圖示 + 一句說明 + 明確下一步 CTA | 「尚無書籍 / 匯入第一本書」按鈕 |
| **載入 Loading** | `ProgressView` + 必要時骨架；長任務可取消 | 搜尋書源中… |
| **錯誤 Error** | 發生什麼 + 如何修 + 重試入口 | 「載入失敗：網路逾時 / 重試」 |

空狀態不可只是一片空白；錯誤不可只 print log。可參考既有 `TTSSettingsView` 的 `emptyView`、`TTSPanelView` 的提示列寫法。

- 空狀態優先 `ContentUnavailableView`（iOS 17+）＋本地化 CTA。
- 長任務（TTS、下載、同步、匯入）除三態外，還需涵蓋 **offline / 慢網路 / 權限被拒 / 中斷恢復**：播放與同步類任務要驗證完整生命週期（啟動→播放/下載→暫停→背景→中斷（電話/通知）→恢復→完成），恢復後進度不丟失。

---

## 10. 頁面原型（Page Archetypes）

設計任一頁前，先判斷它屬於哪種原型，套對應重點：

| 原型 | 目的 / 重點 | 關鍵元件 |
|------|-------------|----------|
| **書架 Library** | 最近閱讀、封面、進度、分組、搜尋 | `List`/grid、進度條、`contextMenu`、`searchable` |
| **閱讀器 Reader** | 文字可讀性、翻頁/捲動、章節、進度、亮度/字體/行距/背景 | `fullScreenCover`、底部控制列、設定 sheet |
| **發現 Discover** | 尊重書源作者的分類與內容，**不擅自重組成平台推薦流**。探索根頁照 Apple Music 搜尋頁的瀏覽分類排成格狀（預設每列兩塊 16:9；右上齒輪開「探索設定」sheet，可關掉「格狀」改成一張張分開的長卡片，或選每列 2–4 欄，三欄以上方塊改正方；字級放大時自動少一欄，輔助字級一律長卡片），上排瀏覽器與自訂頁（右上角 ＋ 跳 alert 命名建立，名稱留空叫「自訂頁」、重名加數字；一頁一塊，圖案同書源的規則；長按重新命名／刪除，刪除先確認），下面「書源」各一塊（書源名開頭的 emoji 當圖案，沒有就用名稱第一個字），自訂頁由元件組成：推薦卡片（一排封面＋書名、簡介）、排行榜（前五名列表，「顯示全部」展開到十名、「收起」）、宮格（兩排各五本）、左右滑動（只有封面）、網絡排行榜（一個榜單每欄四本、橫向翻頁、下一欄露邊）、多分類排行榜（同一書源 2 個以上分類，上方膠囊切換）、錯位瀑布流（三欄卡片往下捲一直載入，一頁一個、固定最後）；除瀑布流外每塊是 `interfaceCardSurface` 白卡，標題就是查看全部連結；排名徽章前三名紅／青／橘底白字、其餘灰底；編輯頁是原生列表（點一下改、左滑刪、拖曳排序、＋新增），新增先選版面，再選書源、發現項（發現頁設定的膠囊卡片，多分類可複選）和標題（預設帶入分類名）；分類標題長按與分類頁右上角的「加入自訂頁」把分類加在那一頁最後當推薦卡片；存在本機 `custom_explore_pages.json`；卡片走 `interfaceCardSurface`：白底，開「分組卡片」時是玻璃；按下即縮、減少動態時改淡出，長按是 legado 書源選單；書源頁的篩選、網頁連結和各處的分組／分類標籤都用共用膠囊 `DSCapsuleLabel`（未選中接界面效果的玻璃、選中主題色；subheadline 中等字重，跟著動態字級），篩選寫成「線路：目前值」；搜尋欄只篩書源（名稱或分組含關鍵字，同 legado `flowExplore(key)`），結果照目前的格狀／長卡片排，搜書在「搜索」分頁；書源頁直接是該源全部分類，右上角齒輪開「發現頁設定」（照參考的分類篩選：每個書源分組一張卡片，標題照書源原樣（☆ 排行榜 ☆，只是一條線的分隔標題改叫「分類」），分區是一列四格的膠囊 `DSCapsuleLabel(fillsWidth:onCard:)`，名稱一格放不下就佔兩格（再長就佔更多，最多一整列）、不換行；選了就只顯示選中的、都不選就全部顯示，「快捷操作」卡有「全部顯示」、書源的按鈕／輸入框／開關（legado-E、MD3 的 button／text／toggle：點了跑書源的 action 腳本，值存在書源的 infoMap；輸入框在名稱後面同一行接灰色的目前值）和網頁連結，連結等 sheet 收起後才開瀏覽器；可搜尋；存在 `discover.categorySelection.<書源 id>`），頭像開書源登入頁；書源頁佈局在探索設定選「雜誌」（下述書店式）或「列表」（legado 式：上方分類標籤、下方所選分類的書卡片列表，沿用查看全部的分頁載入）；探索設定（只跟雜誌有關的關鍵詞、展示數、預加載只在選雜誌時出現）另有首屏配置（探索第一次出現時直接推入某個自訂頁或書源，書源等書源清單到了才推；刪掉當首屏的自訂頁會改回不啟用）、豎排榜單關鍵詞（標題含任一詞走豎排序號，可新增、左滑刪除、恢復預設）、豎排／橫滑展示數（預設 4／全部）、預加載數量（預設 0，仍一次一個排隊）、封面並發數（全 App 的遠端封面下載上限，預設不限制）；瀏覽器全螢幕開、照 Safari：上方只有 ✕ 回探索、沒有標題，網址欄在下方（白底圓角加陰影，起始頁左邊是放大鏡、網頁時是轉碼鍵），工具列能按的鍵用主題色；空白時是 Safari 式起始頁（書籤、最近瀏覽的 64pt 圖示格帶陰影，沒有圖示的網站灰底白字，白色「編輯」膠囊），第一頁按 ‹ 回起始頁；書源頁版面照 Apple Books 書店：區段標題本身就是「查看全部」連結（標題＋`chevron.right`），推薦分類是橫向書架，榜單是可橫滑的排行欄（純數字名次，不上色） | `LazyVGrid` / `LazyVStack` 卡片（`ExploreEntryLabel`）、`fullScreenCover`、分類 section、`scrollTargetBehavior(.viewAligned)` |
| **搜尋 Search** | 書名/作者/URL/書源搜尋，狀態清楚（搜尋中/無結果/錯誤）。列表照 Apple Books 搜尋（iOS 26 截圖量測）：左右 29pt、2:3 小封面（近直角＋短陰影）、旁邊置中三行——書名（粗，最多兩行）、作者、灰字「類型 · 幾源」，沒有簡介、沒有右側按鈕與箭頭，分隔線從文字起到右邊界；有聲書在書名後接灰色標籤（取代封面耳機徽章），第三行只寫「幾源」不再重複類型；英文的源數走 `en.lproj/Localizable.stringsdict` 分單複數（1 source／2 sources）。搜尋欄啟用且空白時列「最近搜索」「最近閱讀」：粗襯線標題＋同基線的「清除」，下方一條通欄分隔線；最近搜索是放大鏡＋關鍵字（最多 5 筆，點了重搜），最近閱讀是最近讀過的 3 本（同一種書籍列）：書架上的書第三行是閱讀進度、點了接著讀；不在書架上的讀過的書（沒加書架就讀／聽過的線上書，或讀過後從書架刪掉的書）照 legado 閱讀記錄的做法，書照舊刪、只留書名作者封面（`OffShelfReadRecords`，最多 10 筆，只有 App 自己的書庫會寫），第三行是多久前讀的、點了用書名重新搜尋，之後加進書架就只以書架那本出現；它的「清除」只清搜尋頁這份清單，不動書架的閱讀紀錄；「全部書源」那一列下面沒有分隔線（iOS 26 靠列表的柔和捲動邊緣）；這兩區是一般列不分 `Section`（iOS 26 的 Section 會在上方多空一段、多畫一條線）。搜尋進度與暫停照 App Store 下載鈕：在「全部書源」那一列右端放圓圈（圈＝已回應比例，中間 ‖ 點了暫停、變 ▶ 再點繼續），左邊「18/27 · 失敗 4」，搜完一起消失；全頁只有這一個暫停控制，不另開灰色帶、不用膠囊按鈕 | `searchable`、`SearchBookListRow`（UIKit 版 `IOS17SearchResultTableCell` 同樣式）、`SearchIdleContent`、`SearchProgressControl`、三態 |
| **設定 Settings** | iOS Settings 風格、分組清楚 | `Form`/`List` insetGrouped、`Toggle`/`Picker`/`NavigationLink` |
| **書源 Book Source** | 區分來源管理、測試、啟用狀態、錯誤狀態 | `List` + 狀態徽章 + `swipeActions` + 測試入口 |
| **詳情 Detail** | 書籍資訊、章節目錄、開始閱讀；小說照 Apple Books 書籍頁、有聲書照 Podcasts 節目頁：封面置中＋書名作者，主按鈕（主色實心）與「加入書架」（中性灰）緊接封面，捲走後書名與主按鈕縮進導覽列；接資訊列、簡介（「更多」）、章節預覽＋「查看全部」 | `BookDetailComponents.swift`（兩種詳情頁共用，不另畫一份） |
| **匯入 Import** | 清楚處理本地檔案 / URL / Legado 書源 / 剪貼簿 | `fileImporter`、分流選單、進度與結果 |
| **TTS / 聽書** | 朗讀控制、語音源/離線語音、章節、睡眠定時 | 控制列、`Slider`、語音選單 |
| **AI 助手 Assistant** | 針對這本書的問答：答案好讀、依據可查、模型與範圍隨手切換 | `Modules/Features/AI/AIChatComponents.swift` 的對話元件（見 §10.1） |

### 10.1 AI 對話介面

閱讀助手的對話畫面參考 OpenMinis 的聊天版面，元件集中在 `AIChatComponents.swift`，新的 AI 對話畫面沿用這一套，不另刻：

- **只有讀者的提問用氣泡**（`AIChatUserBubble`，靠尾端）；AI 回答是頁面上的內文，前面一行「✦ AI 助手」標頭（VoiceOver 標題），不包卡片。
- **次要資訊收進一個控制項**：回答下方只有「複製」與一個「回答範圍／未附書中引用」按鈕，點開才顯示說明卡；不要在每則回答下堆多行提示。
- **輸入框是唯一的浮動層**（`AIChatComposer`）：以 `safeAreaInset(edge: .bottom)` 浮在對話上，內含模型選單、閱讀範圍選單與送出鈕；表面用 `floatingSurfaceBackground`（iOS 26 為 Liquid Glass），**不帶光暈**——光暈在玻璃後面會把整個輸入框染成主色，看起來像已聚焦、也壓低 placeholder 對比。
- 選單裡的單選一律用 `Picker`（附勾選）。選單不會顯示 inline `Picker` 的 label，也不會顯示包住它的 `Section` 標題（iOS 27 實測），所以需要分組名稱時改用 `.menu` 樣式的子選單：模型選單只有一個服務時 inline 列出模型，多個服務時每個服務一個以服務名稱命名的子選單。
- `DisclosureGroup` 只用在 `List`/`Form` 裡。放在一般 `VStack` 時，展開內容的多行 `Text` 會置中排列成倒三角形。
- **AI 批次工作先確認再送出**：「整理已讀人物」「全書與分卷摘要」這類會分批傳送正文的功能，開始前一律列出服務、模型與預計模型呼叫次數讓讀者確認；只處理已讀且本機有正文的章節；離開頁面或退到背景就暫停，已完成的部分保留；用完確認的次數就停下，再次確認才繼續。
- **AI 入口的位置**：經典閱讀器頂部的三橫線選單放「AI 助手」「AI 翻譯」，線上書再加「書籍詳情」；經典底部的圓鈕只留刷新／換源／下載／聽書。Apple Books 的「AI 助手」是選單的第五排（目錄、書籤、搜尋、主題與設定之後），「AI 翻譯」留在下方按鈕列；該列一次最多四顆，超過改成橫向捲動，從尾端（聽書）開始顯示。現代介面維持在書卡裡。
- **AI 全部屬於閱讀Pro**（`PremiumFeature.aiReading`，是否可用一律問 `ReaderPremiumVisibilityPolicy.allowsAI`）。沒有 Pro 時只留上面這些頂部入口、書架選單的「AI 整理書架」和設定的「AI 助手設定」：選單列換成鎖頭並加副標「需要 Pro」，Apple Books 那一排用 `ProLockBadge`，設定列是「需要 Pro」＋列尾鎖頭（`DSSettingsRow(isLocked:)`，同外觀的「啟動圖」），點了都開付費頁；選字選單不放 AI 項目，Apple Books 下方列不放 AI 翻譯。會開 sheet 的選單項目在 iOS 17 走 `DismissalSequencedActionChooser`（見 `Technotes/iOS17MenuModalPresentation.md`）。
- **AI 設定類頁面只往下一層**：「書中人物」是入口頁，底下的「整理已讀人物」「人物卡與朗讀別稱」不再互相連結，也不連回「AI 狀態與診斷」（它在 AI 面板的「更多」裡）。批次數、UTF-16、token 這類帳面數字收進「詳細資料」`DisclosureGroup`；互斥的查看範圍用一個 `Picker`，不用兩個 `Toggle`。

### 10.2 付費頁與 Pro 入口

- **Pro 功能沒 Pro 也看得到，上鎖**：在會用到它的地方照常顯示，列尾「需要 Pro」＋鎖頭，選單列用鎖頭圖示＋副標「需要 Pro」（按鈕 label 直接放兩個 `Text`），點了開付費頁並帶上對應的 `PremiumFeature`。不要整塊藏起來——沒看過的功能沒人會買。唯一例外是選字選單：不放 AI 項目，免得每次劃線都看到付費項目。已產生的資料（字體、筆記、主題）過期後照常可用，只鎖入口。
- **付費頁由上而下**：情境標題（從哪個功能點進來就講哪個，`PremiumPitch`）＋那一類的示意圖（`PaywallShowcase`）→ 方案 → 三大類好處（`PremiumPillar`，點進來的那類排第一）→ 恢復購買與條款；購買按鈕用 `safeAreaInset` 固定在底部，按鈕上寫價格，下面一行回答那個方案最常見的顧慮。
- **誠實**：沒有真實數據就不放評價、使用人數；不寫「開發中、敬請期待」；AI 那一類註明要用自己的 AI 服務金鑰。永久會員的划算用月費換算（`PaywallPricing`），不虛構原價。
- 付費頁從 sheet 裡的控制項開啟時，iOS 17 交給第一層呈現者（先關 sheet，從它的 `onDismiss` 開）；從選單開啟則等選單真的消失。見 `Technotes/iOS17MenuModalPresentation.md`。
- **閱讀Pro 只有一頁**：設定的「閱讀Pro」列永遠開付費頁；那一列用 App 圖示（`AppIconImage`），副標沒 Pro 講「解鎖 AI 閱讀助手與高級個人化」，有 Pro 依方案說「永久會員／已訂閱」——永久不是訂閱。沒 Pro 看到方案；有 Pro 就是它的會員頁（`PaywallMemberPage`）：目前方案、月費用戶的「升級為永久會員」與管理訂閱、恢復購買，三大類用同一套卡片標成已解鎖（`PaywallPlanCard`、`PaywallPillarList` 兩邊共用）。不要另做狀態頁——買完點進去換成另一種長相的頁面，看起來像兩個產品。
- **購買成功是最該記住的一刻**：同一個會員頁當謝謝頁——頁首是 App 自己的圖示（`AppIconImage`，素材 `YueduAppIcon` 深色模式用黑底版；Pro 的識別一律用 App 圖示，不用皇冠之類的 SF Symbol），圖示彈出＋兩圈同形狀的光圈＋一陣彩紙約 2 秒（時間軸隨最後一片結束）、成功觸覺、VoiceOver 播報「已解鎖 閱讀Pro」；方案卡附價格當收據；底部固定「開始使用」，關掉回到原處，剛才點的功能已經解鎖。只在付費頁開著時剛解鎖才出現（購買、延後核准、兌換碼、恢復購買、月費升級永久都算）；減少動態效果時只淡入、不灑彩紙。月費升級永久一定要提醒取消月訂閱。

---

## 11. 閱讀器專屬約束（Reading-first）

- 正文可讀性最高優先：字體、行距、字距、邊距、背景對比可調，且預設舒適。
- 閱讀頁 chrome（工具列/控制列）**可隱藏**，點擊喚出；沉浸時不干擾。
- 翻頁/捲動動畫要穩定、不彈跳；位置以 `(spineIndex, charOffset)` 為準（見 CLAUDE.md）。
- 背景紋理/透明度不得降低文字對比；深色模式有專屬閱讀背景，不直接拿系統色硬套。
- **深色模式是閱讀器自己的狀態**（`GlobalSettings.readerDarkMode`）：三種閱讀介面都有「深色／白天」——經典、現代在工具列，Apple Books 是選單最後一排（點了不收選單）。按鈕的圖示和文字讀這個狀態，不讀背景是不是黑色。沒開「綁定閱讀主題」時自訂背景一律屬於淺色模式、深色模式是黑色；開了之後淺色／深色閱讀主題各管一個模式。「跟隨裝置深淺色」只在綁定時顯示，手動切到跟裝置相反的模式會自動關掉。
- 朗讀（TTS）高亮以「段」為單位與正文同步，不閃爍。
- 中斷恢復：TTS 播放與下載任務在背景、電話、通知中斷後恢復時，保持章節與進度不丟；閱讀位置一律以 `(spineIndex, charOffset)` 恢復（見 CLAUDE.md）。

---

## 12. 設計產出檢查清單

動手前先寫一句**設計方向**（產品對象、主要使用者流程、視覺語言、「使用者最常做的一件事」），再進入以下產出。

每次提出 UI 設計或實作，輸出必含：
1. **頁面目的**（屬於哪種原型）
2. **資訊架構**（主要區塊與層級）
3. **iOS 元件選型**（為何選這些原生元件）
4. **互動流程**（進入 → 操作 → 結果 → 返回）
5. **空 / 載入 / 錯誤** 三態（長任務另涵蓋 offline / 權限被拒 / 中斷恢復，見 §9）
6. **深色模式** 注意事項
7. **無障礙**（Dynamic Type / VoiceOver / 點擊區 / 對比）
8. **SwiftUI 實作建議**（依 §2 選擇情境正確的 title mode，並使用 `DS*` token、`localized()`）
9. **使用者模擬走查**：以三種視角各走一遍流程——主要目標使用者、受限使用者（最大 Dynamic Type / VoiceOver / 單手）、邊緣資料使用者（超長書名、空書架、壞檔）——再判定畫面完成。
10. **渲染證據**：以模擬器/真機截圖驗證各狀態與斷點（三態、深色、最大字級、長本地化字串、鍵盤彈出），不只依賴代碼審查。
11. **可持久修復**：重複出現的設計失敗要沉澱回本文件或檢查規則，不要每次當新問題重講。

---

## 13. 禁止事項

- ❌ 做成網頁 UI（後台、Landing、Dashboard、Tailwind 風格）。
- ❌ 大面積 dashboard 卡片牆 / 不符 iOS 情境的側邊欄、浮動按鈕。
- ❌ 把所有功能塞進同一頁。
- ❌ 為了好看犧牲正文可讀性。
- ❌ 忽略 iOS 導航 / 返回 / Sheet / Tab Bar 慣例。
- ❌ 寫死顏色/字體/間距（繞過 `DS*` token）。
- ❌ 寫死字串（繞過 `localized()`）。
- ❌ 在非主界面根目錄層級使用 `rootTabTitle(_:onScroll:)`；使用 `.inlineLarge`（iOS 17 的 iPhone 只畫成 `.inline`）、`.automatic`、`.large` title mode。
- ❌ 用 `ScrollView`+`VStack`/`HStack` 自刻 list / Form row、自刻 toolbar 或按鈕列、自刻 Toggle / Picker / 彈窗（見 §4）。
- ❌ 互斥選項做成多個獨立 `Toggle`（該用單一選取值的 `Picker` / 單選）；`Toggle` 用內建 label，不要 `.labelsHidden()` + 手刻 HStack。
- ❌ 過度裝飾卡片：22pt+ 圓角、裝飾性漸層/邊框、自訂 Divider；卡片分層用語意表面色與 `DSRadius`（見 §4.1）。
- ❌ 全螢幕 blocking spinner（用骨架或內嵌 `ProgressView`，長任務可取消）。
- ❌ 啟動時一次請求所有權限（見 §8）。
- ❌ 用 `minimumScaleFactor` 縮字救版面（見 §5）。

---

## 參考

- Apple Human Interface Guidelines — https://developer.apple.com/design/human-interface-guidelines/
- HIG Toolbars — https://developer.apple.com/design/human-interface-guidelines/toolbars
- HIG Sheets — https://developer.apple.com/design/human-interface-guidelines/sheets
- HIG Accessibility — https://developer.apple.com/design/human-interface-guidelines/accessibility
- HIG Layout — https://developer.apple.com/design/human-interface-guidelines/layout
- HIG Typography — https://developer.apple.com/design/human-interface-guidelines/typography
- Apple Design Resources — https://developer.apple.com/design/resources/
- SF Symbols — https://developer.apple.com/sf-symbols/
- SwiftUI `toolbarTitleDisplayMode(_:)` — https://developer.apple.com/documentation/swiftui/view/toolbartitledisplaymode(_:)
- SwiftUI `ToolbarTitleDisplayMode.inlineLarge` — https://developer.apple.com/documentation/swiftui/toolbartitledisplaymode/inlinelarge
- Nielsen 10 Usability Heuristics — https://www.nngroup.com/articles/ten-usability-heuristics/
- 本專案設計 token：`Modules/SharedUI/DesignSystem/DesignTokens.swift`
- 在地化規則：見 `yuedu-tour` skill 的 Localization 章節

### 外部設計 skill 參考（知識交叉比對，非本專案規則來源）

社群 app UI/UX agent skill 的**可操作準則已提煉並整合進本文件**（§4/§5/§8/§9/§11/§12/§13）；下表是來源與適用範圍，作為設計決策的交叉比對與靈感來源。任何衝突仍以 [Apple] > [Yuedu] > [建議] 為準（見 §0）。星數為 2026-08 查詢時約略值。

| Skill | 說明 | 適用 |
|-------|------|------|
| [razor-ai/platform-design-skills](https://github.com/razor-ai/platform-design-skills) | 官方 Apple HIG / Material 3 / WCAG 2.2 濃縮成 300+ 條規則，附 Apple HIG PDF | SwiftUI / UIKit / Compose / Web |
| [dickwu/apple-design-skill](https://github.com/dickwu/apple-design-skill)（57★） | Apple HIG 通用化設計審查與改進，53 份指南，框架無關 | Flutter / SwiftUI / RN / Electron |
| [arjitj2/swiftui-design-principles](https://github.com/arjitj2/swiftui-design-principles)（15★） | SwiftUI 原生感抛光原則（間距系統、語意色、原生分組、NavigationStack） | SwiftUI |
| [hamen/material-3-skill](https://github.com/hamen/material-3-skill)（1235★） | MD3 token / 元件 / theming / 10 類審計，次級支援 Flutter | Jetpack Compose / Flutter |
| [flutter/skills](https://github.com/flutter/skills)（2627★，官方） | Flutter 官方 agent skills（響應式佈局、測試、本地化等 workflow） | Flutter |
| [SwiggitySwerve/ux-toolkit](https://github.com/SwiggitySwerve/ux-toolkit) | 25 個通用 UX skill（Nielsen、WCAG、頁面型態審查），支援 OpenCode | 通用（任何框架） |
| [AjnasNB/mobile-app-ux-auditor-skill](https://github.com/AjnasNB/mobile-app-ux-auditor-skill) | 行動 app UX 審計（導航、三態、無障礙、平台適配），含靜態掃描 | Flutter / RN / Swift / Compose |
| [vermont42/iOS-Design-Agent-Skill](https://github.com/vermont42/iOS-Design-Agent-Skill)（8★） | iOS/SwiftUI 反-slop 審美審查（排版、色彩、空間、動態、深度） | SwiftUI |
| [weiping/ixd-design-skill](https://github.com/weiping/ixd-design-skill) | 互動設計 8 階段流程（IA→流程→頁面規格→原型→交付） | 通用（產品設計流程） |
| [EnchStyle/ui-ux-audit-skill](https://github.com/EnchStyle/ui-ux-audit-skill) | 15 類別評分制 UI/UX 審計（含防 AI 常見失敗與三態檢查） | 通用（web / mobile） |
