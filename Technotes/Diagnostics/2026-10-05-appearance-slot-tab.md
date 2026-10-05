# 外觀主題淺色／深色分頁：切淺色看不到狀態列、返回又變深色（2026-10-05）

## 回報

TestFlight 測試者的螢幕錄影。設定是 Pro、自訂主題、跟隨系統關、單獨設定深色主題開，App 為深色。

1. 進「外觀主題」，分頁在「深色」。點「淺色」，整頁變淺色，但時間、電量和頁面標題仍是白字，幾乎看不見。
2. 返回「設定」，又是深色。
3. 再進去，分頁又回到「深色」。

模擬器重現：iPhone 18 Pro Max／iOS 27，`-debug-force-pro`，匯入「山风 - 春水漾」並在兩欄都選它。結果跟影片相同，另外開關與選項的顏色也還是深色那套的青色。

## 根因

- **分頁只是那一頁自己的狀態。** `AppearanceThemeView` 的 `@State themeSlot` 用 `.environment(\.colorScheme)` 改了這一頁的 SwiftUI 內容，也加了 `.preferredColorScheme`。但 `ContentView` 外層的 `.preferredColorScheme`（跟隨系統關時釘住的外觀）會蓋掉內層頁面自己設的偏好。所以 UIKit 畫的狀態列和導覽列、以及用 `colorScheme` 算出的 `.tint`，都停在深色。
- **跟隨系統關掉之後，外觀改不了。** `setAppearanceFollowsSystem(false, currentColorScheme:)` 把關掉那一刻的外觀存下來，之後沒有任何地方能改它。分頁只是預覽，離開頁面就消失。

## 修法（使用者選擇）

- **預覽由 `ContentView` 套用。** 它的 `.preferredColorScheme` 是全 App 唯一的一處，改讀 `GlobalSettings.appearanceWindowColorScheme`：跟隨系統關時是使用者選的外觀，開著時是分頁的預覽（`appearanceSlotPreview`，不存檔）。整個視窗，連狀態列、導覽列、主色一起換。
- **跟隨系統關時，分頁就是 App 的外觀**（`pickAppearanceSlot` 寫入 `appearancePinnedColorScheme`），離開頁面也保留。「單獨設定深色主題」關著時也顯示這個分頁，說明文字改成「跟隨系統關閉時，App 固定使用這裡選的淺色或深色。」
- **跟隨系統開時，分頁仍是預覽。** 從外觀主題打開的頁面也照樣預覽。回到「設定」根頁（`SettingsView.onAppear`）或切換分頁時結束（`endAppearanceSlotPreview`）。
- **跟隨系統開著時預覽並關掉跟隨系統**，就把分頁上的外觀存下來。
- **閱讀器不把預覽當成裝置換外觀**（`alignReaderDarkMode`）：在 iPad 上，閱讀器可能還開在另一個分頁。預覽結束後，回到的外觀照常交給它。

測試：`AppearanceSlotTabTests`、`ReaderBackgroundBindingTests.aPreviewOfTheOtherSlotIsNotTheDeviceTurning`。修正拿掉時，其中三個失敗。模擬器上兩條路都照錄影的步驟走過。
