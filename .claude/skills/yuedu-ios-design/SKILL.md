---
name: yuedu-ios-design
description: iOS native UI/UX design rules for the Yuedu (閱讀) reader app. Use whenever creating or changing any SwiftUI view, screen, sheet, toolbar, list, settings, or other user-facing UI — to make it look like a mature native iOS reader (HIG-compliant), not a web/dashboard UI. Full spec in docs/design.md.
---

# Yuedu Reader — iOS 原生設計規範

動到任何 SwiftUI view / 畫面 / sheet / toolbar / 設定前，遵守本規範。
完整版見 `docs/design.md`（合成 Apple HIG + Design Resources/SF Symbols + Accessibility + Nielsen 十大 + Mobbin 模式）。目標：**像成熟的大型 iOS 原生閱讀器,不是網頁後台**。

## 不可違反的硬規則

1. **頁面標題**：依呈現方式選 title display mode：
   - **導航堆疊內 / 頂部有 toolbar 的推送頁面**：`.inlineLarge`（不要 `.large` 捲動塌縮）。
   - **Sheet（模態彈出）**：`.inline`（不要 `.inlineLarge`、不要 `.large`）。
   ```swift
   // 推送頁面 / 帶 toolbar 的頁面
   .navigationTitle(localized("書架"))
   .toolbarTitleDisplayMode(.inlineLarge)

   // Sheet（模態）
   .navigationTitle(localized("目錄"))
   .toolbarTitleDisplayMode(.inline)
   ```
2. **在地化**：所有對使用者文字 `localized("…")`，三個 lproj（zh-Hant/zh-Hans/en）同步。禁止寫死字串。
3. **設計 token**：顏色/字體/間距/圓角/動畫一律用 `DSColor`/`DSFont`/`DSSpacing`/`DSRadius`/`DSAnimation`（`Modules/SharedUI/DesignSystem/DesignTokens.swift`）。禁止寫死 hex / `.system(size:)` / 硬 duration。缺 token 先補進 `DesignTokens.swift`。
4. **原生元件優先**：`NavigationStack`/`TabView`/`List`/`Sheet`/`Menu`/`Picker`/`Toolbar`/`contextMenu`/`swipeActions`/`searchable`。設定頁用 iOS Settings 風格（`Form`/insetGrouped `List`），不做網頁表單。
5. **SF Symbols 優先**；icon-only 按鈕必須 `accessibilityLabel`（用 `localized`）。
6. **無障礙**：Dynamic Type（用語義字級）、VoiceOver、點擊區 ≥ 44×44pt、深色模式對比足夠、顏色非唯一狀態提示。
7. **三態必做**：每個資料畫面都要設計 空 / 載入 / 錯誤 狀態。
8. **閱讀優先**：裝飾/動畫/透明度不得傷害正文可讀性。

## 禁止

網頁式 UI（dashboard 卡片牆、側欄、Landing、Tailwind 風）、一頁塞滿功能、為好看犧牲可讀性、忽略 iOS 導航/返回/Sheet/Tab 慣例、繞過 `DS*` token 或 `localized()`、有 toolbar 卻不設對應的 title display mode（推送頁 `.inlineLarge` / sheet `.inline`）。

## 設計產出必含

頁面目的（屬哪種原型：書架/閱讀器/發現/搜尋/設定/書源/詳情/匯入/TTS）、資訊架構、元件選型、互動流程、空/載入/錯誤三態、深色模式、無障礙、SwiftUI 實作建議。

→ 細節、token 對照表、頁面原型重點、檢查清單全部在 **`docs/design.md`**，落地前先讀。
