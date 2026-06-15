# Yuedu Reader — iOS 原生設計規範 (design.md)

> 本檔是 Yuedu Reader（閱讀）所有 UI 設計與實作必須遵守的單一準則。
> 目標：做出「**成熟的大型 iOS 原生閱讀器**」，而不是網頁後台、Landing Page、Dashboard 或 Android App。
> 強制套用機制見 `.claude/skills/yuedu-ios-design/SKILL.md`。

合成來源（依優先序）：
1. **Apple Human Interface Guidelines** — 最高權威，衝突時以 HIG 為準。
2. **Apple Design Resources / SF Symbols** — 視覺一致性。
3. **iOS Accessibility（HIG）** — 閱讀器必做。
4. **Nielsen 十大可用性啟發** — 通用 UX 檢查。
5. **Mobbin 真實 App 模式** — 參考成熟 iOS App 的頁面模式，不抄網頁。

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
| H1 | 推送頁面用 `.toolbarTitleDisplayMode(.inlineLarge)`；**Sheet（模態）用 `.inline`** | 見 §2 | `.large` 捲動塌縮 / sheet 用 `.inlineLarge` / 不設定 |
| H2 | 所有對使用者顯示的文字走 `localized("…")`，且三個 lproj 同步 | `Text(localized("書架"))` | `Text("Bookshelf")` |
| H3 | 顏色、字級、間距、圓角、動畫一律用 `DS*` token | `DSColor.textSecondary` | `Color.gray` / 寫死 hex |
| H4 | 圖示優先 SF Symbols，且與文字字重/字級一致 | `Image(systemName: "trash")` | 自製 PNG icon |
| H5 | icon-only 按鈕必須有 `accessibilityLabel` | `.accessibilityLabel(localized("刪除"))` | 只有圖示無語意 |
| H6 | 顏色不得作為唯一狀態提示（需文字/圖示輔助） | 「失敗」紅字+`xmark` | 只靠紅色 |
| H7 | 點擊區域 ≥ 44×44pt | `.frame(minWidth:44,minHeight:44)` | 24pt 純圖示可點區 |
| H8 | 每個資料畫面都要設計 **空 / 載入 / 錯誤** 三態 | 見 §9 | 只做 happy path |
| H9 | 不得做成網頁式 UI（dashboard 卡片牆、側欄、Landing） | 見 §13 | Tailwind 風格 |

---

## 2. 頁面標題與 Toolbar（專案硬規則）

**依呈現方式選標題顯示模式：推送頁面（導航堆疊內 / 頂部有 toolbar）用 `.toolbarTitleDisplayMode(.inlineLarge)`；Sheet（模態彈出）用 `.toolbarTitleDisplayMode(.inline)`。**

```swift
// ✅ 標準寫法
SomeContent()
    .navigationTitle(localized("書架"))
    .toolbarTitleDisplayMode(.inlineLarge)
    .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                addBook()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(localized("新增書籍"))
        }
    }
```

規則細節：
- **推送頁面**用 `.inlineLarge`：標題以大字呈現但**保持 inline、不隨捲動塌縮**——這是本專案推送頁的統一外觀。
- **Sheet（模態）**用 `.inline`：模態彈出的高度通常較矮、頂部需放 checkmark/取消等動作，標準 inline 小標題最貼合 iOS sheet 慣例（不要用 `.inlineLarge`）。
- **不要**再用 `.navigationBarTitleDisplayMode(.large)`（會捲動塌縮）。既有頁面若用了舊 modifier，動到時順手換成對應模式。
- 主要操作放 **右上角**（`.topBarTrailing`）；返回/取消放左上角（多數情況交給系統）。
- Toolbar 圖示用 `DSFont.toolbarIcon` / `DSFont.toolbarIconLarge`，顏色 `DSColor.accent` 或 `DSColor.textSecondary`。

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

> 這些都映射到 system colors，**天生支援 light/dark mode**。不要用 `Color.gray`、`Color(hex:)`、品牌硬色。

### 字體 `DSFont`
`caption2 / caption / subheadline / body / bodyBold / headline / title2 / title / largeTitle`，等寬 `monospaced(size:)`，toolbar `toolbarIcon / toolbarIconLarge`。
- 全部基於語義字級 → **自動支援 Dynamic Type**。不要 `.font(.system(size: 14))` 寫死。

### 間距 `DSSpacing`
`xs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32`。頁面外距用 `xl`，群組間 `lg`，元素內 `sm`。

### 圓角 `DSRadius`
`sm=6（標籤/小按鈕） / md=8（按鈕/輸入框） / lg=12（卡片/對話框） / xl=16（圖片容器）`。

### 動畫 `DSAnimation`
`fast=0.15（即時回饋） / standard=0.28（轉場） / slow=0.4（展開）`。不要硬寫 duration。

---

## 3.1 iPad / 自適應佈局

iPad 是同一個 iOS app 的原生自適應版，不是另一個 app root。共享資料模型與 reader engine 在 `Modules/Core` / `Modules/Services`，feature UI 與設定在 `Modules/Features`，design token 在 `Modules/SharedUI/DesignSystem`；iPad 專屬 shell 放 `Targets/Yuedu/iPad/`、iPad reader UI 放 `Modules/Features/Reader/iPad/` 等明確目錄，避免散落機型判斷。

- 佈局用 size class、scene/window size 與 readable width 驅動；不要散落 `UIDevice.model` 或機型字串判斷。
- iPhone 維持 compact/portrait 的底部 Tab Bar；iPad regular 使用系統 `TabView.sidebarAdaptable` 或 `NavigationSplitView` 等 HIG 原生容器，不自刻側欄。
- iPad 橫豎向與視窗 resize 都要能重排；需要 reader 重分頁時，以 SwiftUI 已量到的 viewport size 作為唯一觸發來源。
- 寬螢幕設定頁、sheet、清單與 reader overlay 使用 `DSLayout.readable*Width` token 限制行長；不要直接寫 640/760/960 等 magic number。
- 閱讀器橫向雙頁是 reader 專屬模式：iPad regular + landscape 才自動啟用；切回直向或 iPhone 時回單頁，閱讀位置以 `(spineIndex, charOffset)` 保持。
- iPad 專屬檔案可以包裝共享 view，但不得複製業務邏輯；狀態、同步、書源、閱讀進度仍由共享 model / coordinator 負責。

---

## 4. iOS 原生元件選型

| 需求 | 用 | 不要用 |
|------|-----|--------|
| 頁面導航 | `NavigationStack` + `navigationDestination` | 自刻 push 動畫 |
| 主分頁 | `TabView`（底部 Tab Bar） | 自刻底部列 / 側欄 |
| 清單 / 設定 | `List`（`.plain` 或 `.insetGrouped`） | `ScrollView`+手刻 row、網頁表單 |
| 短流程 / 次要任務 | `.sheet`（可加 `.presentationDetents`） | 全螢幕擋住 |
| 重任務 / 沉浸（閱讀器） | `.fullScreenCover` | sheet 硬塞 |
| 就地選擇 | `Menu` / `Picker` | 自刻下拉 |
| 長按操作 | `.contextMenu` | 自刻浮層 |
| 列項滑動操作 | `.swipeActions` | 自刻手勢 |
| 破壞性確認 | `.confirmationDialog` / `.alert` | 自刻彈窗 |
| 搜尋 | `.searchable` 或既有 `DSSearchBar` | 網頁式 search box |
| 載入 | `ProgressView` | 自刻 spinner |

設定頁一律 **iOS Settings 風格**（`Form` / `List` `.insetGrouped` 分組 + section header），不要做成網頁表單。

---

## 5. 排版與字級

- 用語義字級表達層級：`largeTitle`/`title` 標題 → `headline` 區塊標題 → `body` 正文 → `subheadline`/`caption` 輔助。
- **支援 Dynamic Type**：不寫死 pt；長字串用 `.lineLimit` + 截斷或換行策略，避免大字級爆版。
- 對齊與留白勝過分隔線；分隔線只在 `List` 語義需要時出現。

---

## 6. SF Symbols / 視覺一致性

- 圖示**優先 SF Symbols**；字重、尺寸、語意與相鄰文字一致（同一列圖示風格統一，不混 fill / outline）。
- 不自創不必要的 icon style；功能性圖示服務「閱讀、選書、搜尋、設定」，不裝飾。
- 用 system colors 與 `DSColor`，不硬寫網頁品牌色（搜尋引擎 brand 色已有專屬 token）。
- 書封缺圖用 `DSColor.coverGradients` 生成漸層佔位，不要空白方塊。

---

## 7. 無障礙 Accessibility（閱讀器必做）

每個畫面都要過這份清單：
- [ ] 正文、設定項、按鈕文字支援 **Dynamic Type**。
- [ ] 所有 **icon-only 按鈕** 有 `accessibilityLabel`（用 `localized`）。
- [ ] 點擊區 ≥ **44×44pt**。
- [ ] 顏色**不是**唯一狀態提示（配文字/圖示）。
- [ ] 深色模式下對比足夠（用 `DSColor`，勿低對比疊透明）。
- [ ] 重要功能用 **VoiceOver** 能理解操作順序與結果。
- [ ] 閱讀頁避免動畫、透明、背景紋理干擾文字辨識。
- [ ] 裝飾性元素 `.accessibilityHidden(true)`；相關元素用 `.accessibilityElement(children: .combine)`。

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

---

## 9. 狀態設計（每頁必備三態）

| 狀態 | 必含 | 範例 |
|------|------|------|
| **空狀態 Empty** | 圖示 + 一句說明 + 明確下一步 CTA | 「尚無書籍 / 匯入第一本書」按鈕 |
| **載入 Loading** | `ProgressView` + 必要時骨架；長任務可取消 | 搜尋書源中… |
| **錯誤 Error** | 發生什麼 + 如何修 + 重試入口 | 「載入失敗：網路逾時 / 重試」 |

空狀態不可只是一片空白；錯誤不可只 print log。可參考既有 `TTSSettingsView` 的 `emptyView`、`TTSPanelView` 的提示列寫法。

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

---

## 12. 設計產出檢查清單

每次提出 UI 設計或實作，輸出必含：
1. **頁面目的**（屬於哪種原型）
2. **資訊架構**（主要區塊與層級）
3. **iOS 元件選型**（為何選這些原生元件）
4. **互動流程**（進入 → 操作 → 結果 → 返回）
5. **空 / 載入 / 錯誤** 三態
6. **深色模式** 注意事項
7. **無障礙**（Dynamic Type / VoiceOver / 點擊區 / 對比）
8. **SwiftUI 實作建議**（含 `.toolbarTitleDisplayMode(.inlineLarge)`、`DS*` token、`localized()`）

---

## 13. 禁止事項

- ❌ 做成網頁 UI（後台、Landing、Dashboard、Tailwind 風格）。
- ❌ 大面積 dashboard 卡片牆 / 不符 iOS 情境的側邊欄、浮動按鈕。
- ❌ 把所有功能塞進同一頁。
- ❌ 為了好看犧牲正文可讀性。
- ❌ 忽略 iOS 導航 / 返回 / Sheet / Tab Bar 慣例。
- ❌ 寫死顏色/字體/間距（繞過 `DS*` token）。
- ❌ 寫死字串（繞過 `localized()`）。
- ❌ 有 toolbar 的頁面不用 `.toolbarTitleDisplayMode(.inlineLarge)`。

---

## 參考

- Apple Human Interface Guidelines — https://developer.apple.com/design/human-interface-guidelines
- Apple Design Resources — https://developer.apple.com/design/resources/
- SF Symbols — https://developer.apple.com/sf-symbols/
- HIG Accessibility — https://developer.apple.com/design/human-interface-guidelines/accessibility
- Nielsen 10 Usability Heuristics — https://www.nngroup.com/articles/ten-usability-heuristics/
- Mobbin（真實 App 模式參考） — https://mobbin.com/
- 本專案設計 token：`Modules/SharedUI/DesignSystem/DesignTokens.swift`
- 在地化規則：見 `yuedu-tour` skill 的 Localization 章節
