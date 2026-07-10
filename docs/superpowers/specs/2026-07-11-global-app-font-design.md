# Yuedu 全局字體設計

## 目標

在「外觀主題」新增「全局字體」設定，讓使用者以系統字體或已匯入字體改變 Yuedu 的 App 介面字體。全局字體與閱讀正文的字體選擇彼此獨立，但共用同一個匯入字體庫。

## 範圍

全局字體套用於一般 App 介面文字，包括書架、發現、搜尋、RSS、設定、書籍詳情、Reader 周邊控制介面、導航標題及 Tab 標籤。字級層級、粗細語意與 Dynamic Type 必須保留。

以下內容不受全局字體影響：

- CoreText 閱讀正文；其字體仍由 `selectedReaderFontPostScript` 控制。
- EPUB 內嵌字體與內容 CSS 指定的字體。
- 程式碼、規則及 URL 等刻意使用的等寬字體。
- SF Symbols、圖片內文字及外部網頁內容。

## 資料模型與保存

- 保留 `GlobalSettings.userFonts` 作為唯一的匯入字體清單。
- 新增 `GlobalSettings.selectedGlobalFontPostScript`，使用獨立的 UserDefaults key 保存；`nil` 代表系統字體。
- `selectedGlobalFontPostScript` 與 `selectedReaderFontPostScript` 不互相覆寫。
- 將目前偏向閱讀器命名的匯入流程拆成共用字體庫操作：匯入本身只新增至 `userFonts`，呼叫端再決定選為全局字體或閱讀字體。
- 刪除共用字體時，同時檢查兩個選擇；正在使用該字體的設定各自回到系統字體。
- App 啟動仍由 `UserFontStorageManager.registerAllOnLaunch()` 註冊所有已匯入字體。

## 介面設計

`AppearanceThemeView` 在外觀主題與 Reader 介面／Tab 設定附近新增「全局字體」導航列，顯示目前選擇的字體名稱。點入 `GlobalFontSettingsView` 後使用原生 `Form`／`List` 呈現：

1. 「系統字體」固定置頂。
2. 「已匯入字體」列出 `GlobalSettings.userFonts`，並以勾選符號標示目前的全局選擇。
3. 「匯入字體…」使用既有 TTF／OTF `fileImporter`；從此處匯入後選為全局字體，但不改變閱讀字體。
4. 已匯入字體提供原生 swipe delete，刪除前以 confirmation dialog 說明它會從共用字體庫移除。

選擇字體後立即套用，不需要額外的完成按鈕。子頁是 pushed settings detail，使用 `.toolbarTitleDisplayMode(.inline)`。所有新增文字同步加入繁體中文、簡體中文及英文在地化。

當尚未匯入任何字體時，畫面仍保留可選的系統字體，並顯示匯入提示；因此不存在無法操作的空白狀態。檔案挑選期間由系統文件選擇器提供狀態，匯入失敗則以本地化 alert 顯示原因。

## 字體套用架構

新增集中式 `GlobalAppTypography`：

- 接收目前的全局 PostScript 名稱。
- 依 `body`、`caption`、`headline`、`title` 等語義樣式產生 SwiftUI `Font`。
- 自訂字體使用 `Font.custom(_:size:relativeTo:)`，維持 Dynamic Type；無法建立字體時回退對應的系統語義字體。
- 同時提供 UIKit 語義字體解析，供原生導航列與 Tab 標籤使用。

`ContentView` 是套用入口：它觀察 `selectedGlobalFontPostScript`，將正文預設字體注入 SwiftUI 環境，並在字體或 Dynamic Type 改變時更新 UIKit 導航／Tab 字體。`DSFont` 改由同一解析器產生語義字體；現有直接指定系統語義字體的使用者可見文字，則遷移至 `DSFont`。固定尺寸的 SF Symbol、閱讀渲染字體與等寬用途不做機械替換。

UIKit bridge 僅更新字體屬性，保留目前主題已設定的顏色、背景、材質與其他 appearance 屬性。切回系統字體時恢復對應的系統語義字體。

## 資料流

1. 使用者在全局字體頁選擇字體。
2. `selectedGlobalFontPostScript` 寫入 UserDefaults 並發布變更。
3. `ContentView` 更新 `GlobalAppTypography` 的有效選擇。
4. SwiftUI 環境字體、`DSFont` 與 UIKit navigation／tab bridge 使用相同解析結果刷新。
5. Reader 的 CoreText pipeline 繼續只讀取 `selectedReaderFontPostScript`，因此正文不變。

## 錯誤與回退

- 保存的 PostScript 名稱若不在 `userFonts` 或無法建立字體，介面回退系統字體，並清除失效選擇。
- 匯入沿用既有 `UserFontStorageError`，僅接受 TTF／OTF。
- 重複匯入同一 PostScript 字體時沿用現有去重行為。
- 刪除失敗不阻止清單與選擇狀態保持一致；檔案系統錯誤記錄至既有日誌路徑。

## 測試與驗證

先新增失敗測試，再實作：

- 全局與閱讀字體選擇彼此獨立。
- 閱讀設定匯入的字體會出現在共用 `userFonts`，可被全局字體選取。
- 從全局頁匯入字體不會改變閱讀字體。
- 刪除字體會清除正在引用它的全局／閱讀選擇。
- `GlobalAppTypography` 能解析自訂字體，無效名稱會回退系統語義字體。
- 自訂字體仍依 Dynamic Type 的相對 text style 縮放。

依專案規則不直接執行長時間 `xcodebuild`。本地先執行 `ruby scripts/check_localizations.rb`、`git diff --check` 與來源層級檢查，再提供最小的單一測試類別 `xcodebuild` 指令給使用者執行。

## 完成條件

- 外觀主題可進入全局字體設定並即時切換。
- 閱讀設定既有匯入字體全部出現在全局字體清單。
- App 一般介面文字一致套用全局字體，語義大小與 Dynamic Type 不退化。
- 閱讀正文的字體選擇與顯示不受全局字體切換影響。
- 重新啟動後兩個字體選擇各自恢復。
