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
| H1 | title mode：僅主界面根目錄（Tab 根頁）使用 `.inlineLarge`（經 `toolbarTitleDisplayModeInlineLargeOrInline()`），其餘一律 `.inline` | 見 §2 矩陣 | 在 pushed / sheet 用 `.inlineLarge`，或使用 `.automatic` / `.large` / 裸 `.inlineLarge` |
| H2 | 所有對使用者顯示的文字走 `localized("…")`，且三個 lproj 同步 | `Text(localized("書架"))` | `Text("Bookshelf")` |
| H3 | 顏色、字級、間距、圓角、動畫一律用 `DS*` token | `DSColor.textSecondary` | `Color.gray` / 寫死 hex |
| H4 | 圖示優先 SF Symbols，且與文字字重/字級一致 | `Image(systemName: "trash")` | 自製 PNG icon |
| H5 | icon-only 按鈕必須有 `accessibilityLabel` | `.accessibilityLabel(localized("刪除"))` | 只有圖示無語意 |
| H6 | 顏色不得作為唯一狀態提示（需文字/圖示輔助） | 「失敗」紅字+`xmark` | 只靠紅色 |
| H7 | 一般互動的 **hit region** 預設至少 **44×44pt**；**28×28pt** 只描述受限 compact 情境的最小 visible control size，必須搭配充分 spacing，不能當作縮小一般 hit target 的理由；reader chrome 與 primary actions 維持至少 44×44pt hit region | 擴大 hit region 且控制間保留間距 | 把 28pt visible control 直接當一般 hit target |
| H8 | 每個資料畫面都要設計 **空 / 載入 / 錯誤** 三態 | 見 §9 | 只做 happy path |
| H9 | 不得做成網頁式 UI（dashboard 卡片牆、側欄、Landing） | 見 §13 | Tailwind 風格 |
| H10 | accessibility modifier 只能加在**該元素本身**，不能加在容器上（會往下傳給每個子元素） | 每顆 `Button` 各自 `.accessibilityLabel` | 在包住三顆按鈕的 `HStack` 上加一個 label |

---

## 2. 頁面標題、Toolbar 與 Sheet

### 2.1 標題模式矩陣

先判斷畫面是否為「主界面根目錄」（Tab 根頁）；規則只有兩種狀態，toolbar 是否存在不是決定條件。

| 情境 | title mode | 原因 / 注意事項 |
|------|------------|-----------------|
| **主界面根目錄**（Tab 根頁） | `.inlineLarge` | 唯一允許 `.inlineLarge` 的層級。統一經 `toolbarTitleDisplayModeInlineLargeOrInline()`（iOS 18+ 顯示 `.inlineLarge`，iOS 17 退回 `.inline`）。 |
| Pushed detail（導航堆疊內的詳情、設定子頁） | `.inline` | 維持清楚的返回層級，為導覽與動作保留空間。 |
| Sheet / modal task | `.inline` | 標題精簡，leading / trailing 分別容納取消與完成。 |
| Reader / immersive surface | `.inline` | 依沉浸狀態與 chrome 顯示需求決定呈現；不使用 `.inlineLarge`。 |

**主界面根目錄白名單**：書架 `HomeView`、探索 `ExploreHomeView`、RSS `RSSListView`、設定 `SettingsView`（搜尋 tab 根頁目前為 `.inline`，不在此列）。名單以外的頁面一律 `.inline`。

`.inlineLarge` 是主界面根目錄的固定樣式（App Store / Apple Maps 式的大型標題、同時保留完整 toolbar），**不是全域預設**：根目錄以外任何層級都禁用。注意 iOS 17 沒有 `.inlineLarge`，因此必須透過 `toolbarTitleDisplayModeInlineLargeOrInline()`；**禁止裸用 `.toolbarTitleDisplayMode(.inlineLarge)`**（舊系統無退化行為）。`inlineLarge` 會讓 leading / center items 移入 overflow，根頁若有此類 item 仍需驗證可用寬度與本地化。

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
`fast=0.15（即時回饋） / standard=0.28（轉場） / slow=0.4（展開）`。不要硬寫 duration。`DSAnimation` 只是時序 token，不會自行讀取 Reduce Motion；每個含位移、縮放或連續運動的 view 都必須依環境值切換動畫策略。

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
| **發現 Discover** | 尊重書源作者的分類與內容，**不擅自重組成平台推薦流** | 原生 `List`、分類 section |
| **搜尋 Search** | 書名/作者/URL/書源搜尋，狀態清楚（搜尋中/無結果/錯誤） | `searchable`、結果列、三態 |
| **設定 Settings** | iOS Settings 風格、分組清楚 | `Form`/`List` insetGrouped、`Toggle`/`Picker`/`NavigationLink` |
| **書源 Book Source** | 區分來源管理、測試、啟用狀態、錯誤狀態 | `List` + 狀態徽章 + `swipeActions` + 測試入口 |
| **詳情 Detail** | 書籍資訊、章節目錄、開始閱讀 | 大標 + 後設資料 + 主 CTA |
| **匯入 Import** | 清楚處理本地檔案 / URL / Legado 書源 / 剪貼簿 | `fileImporter`、分流選單、進度與結果 |
| **TTS / 聽書** | 朗讀控制、語音源/離線語音、章節、睡眠定時 | 控制列、`Slider`、語音選單 |

---

## 11. 閱讀器專屬約束（Reading-first）

- 正文可讀性最高優先：字體、行距、字距、邊距、背景對比可調，且預設舒適。
- 閱讀頁 chrome（工具列/控制列）**可隱藏**，點擊喚出；沉浸時不干擾。
- 翻頁/捲動動畫要穩定、不彈跳；位置以 `(spineIndex, charOffset)` 為準（見 CLAUDE.md）。
- 背景紋理/透明度不得降低文字對比；深色模式有專屬閱讀背景，不直接拿系統色硬套。
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
- ❌ 在非主界面根目錄層級使用 `.inlineLarge`；裸用 `.toolbarTitleDisplayMode(.inlineLarge)`（iOS 17 不支援，無退化行為）；使用 `.automatic` / `.large` title mode。
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
