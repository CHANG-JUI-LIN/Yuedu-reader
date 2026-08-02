# 外觀主題「跟隨系統」開關設計

## 背景與目標

目前 App 的外觀主題由 SwiftUI 的 `ColorScheme` 驅動，因此系統從淺色切換到深色時，整個 App 會同步切換。使用者需要一個設定，讓 App 在關閉「跟隨系統」後固定在關閉當下的淺色或深色外觀，並在下次啟動時保持這個選擇。

本次只處理 App 外觀的跟隨行為，不改變既有「閱讀器跟隨系統主題」設定的獨立語意，也不新增另一組淺色／深色選擇器。

## 採用方案

在 App 根層管理一個持久化的外觀跟隨狀態與固定色彩模式：

- `appearanceFollowsSystem`：是否將 App 外觀交給系統，預設為 `true`，確保既有安裝升級後行為不變。
- `appearancePinnedColorScheme`：關閉跟隨時保存的 `light`／`dark` 模式。
- 關閉開關時，從設定頁目前實際顯示的 `ColorScheme` 保存固定模式；開啟開關時移除 App 層級的固定覆寫，但保留上次固定值作為下一次關閉時的預設候選。

選擇根層 `preferredColorScheme` 的原因是它能讓 SwiftUI 後代畫面、工具列、設定頁、主題背景與閱讀器共享同一個有效外觀，不需要在各個畫面各自判斷系統狀態。UIKit window trait override 不採用，因為它會增加多場景與 SwiftUI 環境不同步的風險；新增人工淺／深色選擇器則超出本需求。

## UI 與文案

在 `AppearanceThemeView` 的「主題切換」區塊最上方加入原生 `Toggle`：

- 標題使用 `localized("跟隨系統")`。
- 使用既有設定列樣式與設計 token，不新增自繪開關。
- 關閉時顯示說明，明確表達「切換系統深色模式不會影響 App 外觀」；開啟時顯示 App 會依系統淺／深色自動切換。
- 既有「單獨設定深色主題」與「綁定閱讀主題」保留在同一 section，順序與條件顯示不改變。
- 新增的說明文案同步放入 `zh-Hant`、`zh-Hans`、`en`，所有文字仍經由 `localized(...)` 取得。

主題網格、深色主題分頁與自訂主題預覽仍可使用既有的局部 `preferredColorScheme`。預覽只改變預覽畫面，不應覆寫已保存的 App 固定模式。

## 資料流與行為

1. `GlobalSettings` 讀取／保存兩個新的 UserDefaults 值。
2. `ContentView` 計算有效外觀：跟隨系統時使用環境 `colorScheme`；固定時使用 `appearancePinnedColorScheme`。
3. App 根視圖以有效外觀設定 `.preferredColorScheme`；主題選取、`ActiveAppThemes`、頁面背景與 root tab 圖示解析也使用同一個有效外觀。
4. 設定頁的 Toggle 使用自訂 Binding。從開啟切到關閉時，先記下目前頁面顯示的外觀，再保存 `appearanceFollowsSystem = false`；從關閉切到開啟時恢復系統外觀。
5. 關閉跟隨後，系統 appearance notification 不會再改變 App 後代的 `ColorScheme`，因此不會觸發外觀主題或閱讀器的系統切換路徑。
6. `readerFollowSystemTheme` 仍是閱讀器自己的設定；本次不把兩個設定合併，也不改動閱讀器快速主題面板的既有選項。

## 邊界情況

- 舊版本沒有新 UserDefaults 值時，跟隨系統必須預設為開啟。
- 若固定模式值缺失或不是 `light`／`dark`，以安全的淺色值作為資料層 fallback；這只處理資料遺失，不新增外觀切換 retry 路徑。
- 使用者在主題頁預覽深色分頁時關閉開關，固定的是目前畫面看見的模式；主題預覽狀態本身不會被持久化成另一項設定。
- 「單獨設定深色主題」開啟時，固定淺色會使用淺色主題槽，固定深色會使用深色主題槽；系統切換不會在兩個槽位間切換。
- 啟用跟隨後，原本保存的固定模式仍可保留，下一次關閉時會以當下顯示模式重新保存，避免使用者看到過時模式。

## 測試與驗收

- 在 `AppearanceThemePresetTests` 增加 `GlobalSettings` 狀態測試：預設值、關閉時保存當下模式、重新開啟恢復跟隨，以及無效保存值的安全解析。
- 執行直接相關測試類別：

  `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme Yuedu-Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/AppearanceThemePresetTests'`

- 執行本地化檢查：`ruby scripts/check_localizations.rb`。
- 執行格式檢查：`git diff --check`。
- 驗收重點：開關預設開啟；關閉後切換系統深色模式時 App 外觀、主題色、頁面背景與閱讀器所在環境不變；重新開啟後恢復跟隨系統。
