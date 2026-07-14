# 頁首頁尾編輯器設計規格

日期：2026-07-14

## 目標

將現有固定的頁眉左／中／右欄位與固定頁腳，改為可在整個分頁閱讀畫面自由排列的資訊元件。使用者可直接在閱讀頁預覽中新增、拖曳、編輯或刪除元件，並藉由基準線吸附完成精準對齊。

本功能保留 Yuedu 的原生 iOS 視覺與設計 token，只採用參考產品的功能概念，不複製其介面。

## 已確認的產品決策

- 功能名稱為「頁首頁尾編輯」。
- 點擊現有元件後，在元件附近顯示錨定式「編輯／刪除」小選單。
- 元件可覆蓋正文；拖曳不改 CoreText 版面，也不觸發重新分頁。
- 元件可在整個畫面內擺放，包括狀態列與 Home Indicator 附近；安全區是吸附參考，不是禁區。
- 元件必須完整留在畫面內，不能保存成無法再次點選的位置。
- 所有書共用一套全域配置，橫豎畫面與不同裝置共用比例座標。
- 每個元件可獨立設定字體、大小、粗細、顏色與透明度。
- 支援可匯入、可分享的動態 SVG 電量模板。
- 第一版只支援分頁閱讀；捲動閱讀維持不顯示固定頁首頁尾。

## 非目標

- 每本書獨立配置。
- 橫向與直向各自保存配置。
- 多套頁首頁尾預設管理。
- 捲動閱讀的固定浮動元件。
- 元件背景、圓角、邊框、陰影或自訂寬度等進階裝飾。
- SVG JavaScript、網路資源或任意程式執行。

## 資料模型

新增有版本號的全域 `ReaderOverlayLayout`，以元件陣列取代現有的欄位位置字典與固定頁腳組合。

```swift
struct ReaderOverlayLayout: Codable, Equatable {
    var version: Int
    var components: [ReaderOverlayComponent]
    var contentReservations: ReaderOverlayContentReservations
}

struct ReaderOverlayComponent: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: ReaderOverlayComponentKind
    var position: ReaderOverlayNormalizedPosition
    var configuration: ReaderOverlayComponentConfiguration
    var style: ReaderOverlayComponentStyle
}

struct ReaderOverlayNormalizedPosition: Codable, Equatable {
    var x: Double
    var y: Double
}

struct ReaderOverlayContentReservations: Codable, Equatable {
    var top: Double
    var bottom: Double
}
```

`ReaderOverlayContentReservations` 保存正文頂部與底部的固定保留空間。它與元件座標完全分離：拖曳、刪除或新增元件不改保留空間，因此不會重新分頁。只有使用者另外修改正文留白設定時，才更新保留空間並走既有 CoreText layout invalidation。

`x`、`y` 表示元件中心相對於完整閱讀視窗的比例，正常範圍為 `0...1`。實際顯示時必須依元件尺寸與視窗尺寸夾限，確保完整可見；保存拖曳結果前再次正規化。

`ReaderOverlayComponentStyle` 保存：

- 字體來源：系統字體、目前閱讀字體，或匯入字體的 PostScript 名稱。
- 字體大小。
- 字重。
- 顏色：主題文字色或自訂色值。
- 透明度。

匯入字體沿用 `UserFontStorageManager`。若 PostScript 字體已不存在，渲染器退回系統字體，不改寫使用者保存的原設定，以便字體重新匯入後恢復。

## 元件種類

第一版支援：

- 書名。
- 章節名。
- 本章頁碼。
- 總進度文字。
- 總進度條。
- 當前時間。
- 當前日期。
- 星期。
- 電量。
- 本次閱讀時長。
- 預估剩餘時間。
- 自訂文字。

資訊值由單一 `ReaderOverlayContentSnapshot` 提供，執行時畫布與編輯預覽共用相同解析器，避免兩套格式邏輯。

剩餘時間使用本書有效閱讀工作階段的字符速度與剩餘字符數估算。當有效閱讀資料不足、剩餘字符數未知或進度太低時顯示 `--`，不顯示看似精確但不可靠的數字。

## 儲存與資產

元件配置資料量小，由 `GlobalSettings` 以 Codable JSON／Data 保存到 UserDefaults，草稿只在按下完成時編碼並寫入一次。動態 SVG 不直接內嵌在元件中，而由 `ReaderOverlaySVGAssetStore` 保存至 Library 下的專用目錄；元件只引用 SVG 資產 UUID。

SVG 資產包含：

- UUID。
- 顯示名稱。
- 原始 SVG 字串。
- 驗證版本。
- 可選的預覽快取資訊。

刪除仍被元件引用的 SVG 時，先要求改用系統圖示或另一模板。若資產檔案在磁碟上遺失，電量元件自動退回系統電池圖示。

## 動態 SVG 電量模板

SVG 使用受限制的 `data-yuedu-*` 標記，不允許 JavaScript。第一版辨識：

- `data-yuedu-role="battery-level"`：依 `0...1` 電量調整其可見填充比例。
- `data-yuedu-role="battery-percent"`：將文字內容替換為整數百分比。
- `data-yuedu-visible="charging"`：僅在充電或已充滿時顯示。
- `currentColor`：套用元件設定的顏色。

`battery-level` 元素以裁切方式表示電量，預設由左向右。模板可用 `data-yuedu-direction` 指定 `left-to-right`、`right-to-left`、`bottom-to-top` 或 `top-to-bottom`；其他值視為匯入錯誤。這套規則只改可見裁切範圍，不任意重寫 path 資料。

模板必須具有有效 `viewBox`，或可由正數 `width`／`height` 推導。匯入時拒絕：

- 超過設定上限的檔案。
- `script`、`foreignObject`、`iframe`、`object`、`embed`。
- `on*` 事件屬性。
- 外部 `href`／`xlink:href`、遠端 CSS 與網路字體。
- 無法解析的 XML／SVG 根節點。

驗證後的 SVG 只在模板、尺寸、顏色、電量或充電狀態等渲染輸入改變時重新生成，並按這些輸入快取；一般畫面更新不重複解析。

SVG 管理畫面支援原生檔案匯入與匯出。匯出內容是已通過驗證、仍保留 `data-yuedu-*` 標記的單一 `.svg`，因此其他使用者不需要額外 JSON 即可分享與匯入。

## 畫布與渲染

`ReaderOverlayCanvas` 同時服務正式閱讀與編輯模式：

- 正式閱讀模式不接受點擊，避免干擾翻頁與文字選取。
- 編輯模式接受選取與拖曳，並顯示選取外框、基準線與操作選單。
- 元件永遠作為 SwiftUI 覆蓋層顯示，不烘焙進 CoreText 頁面或 page-curl 紋理。
- 頁面切換只更新內容快照，不重建元件配置。

自由移動的元件不參與文字排版。現有正文上下保留空間在遷移時轉成 `contentReservations`，拖曳元件不改動該空間；舊有「頁眉離頂／頁腳離底」只用於遷移初始元件位置，之後由比例座標取代。

## 編輯流程

入口位於閱讀設定，名稱為「頁首頁尾編輯」。現有逐項頁眉位置 Picker 與固定頁腳位置控制由此入口取代；正文與頁首頁尾之間的既有閱讀留白設定不由拖曳器自動修改。

進入編輯器時複製正式配置成草稿：

- `取消` 捨棄整份草稿。
- `完成` 驗證後一次保存，避免拖到一半被永久寫入。
- 點元件後顯示錨定式「編輯／刪除」小選單。
- 開始拖曳時收起小選單。
- 刪除只修改草稿並顯示可復原提示。
- 新增使用原生 sheet；新增元件先放在畫面中心並自動選取。
- 編輯元件使用原生 sheet／Form，依元件種類顯示適用設定。

離開編輯器時不需要重新分頁；正式畫布直接讀取新配置。只有既有正文留白設定另外變更時才走原本的 CoreText layout invalidation 流程。

## 拖曳與吸附

`ReaderOverlaySnapEngine` 是不依賴 SwiftUI 的純邏輯元件，輸入候選 frame、視窗、安全區與其他元件 frame，輸出夾限後位置及可見基準線。

吸附候選包含：

- 畫面水平與垂直中心。
- 畫面四邊。
- 安全區四邊。
- 其他元件的中心與四邊。

每個軸只選距離最近且落在 6pt 閾值內的候選，避免同時跳向多條線。進入新的吸附目標時觸發一次輕量觸覺回饋，持續停留時不重複震動。拖曳結束後隱藏基準線並保存正規化位置。

## 可存取性

- 編輯器維持合理的 VoiceOver 元素順序。
- 每個元件宣告資訊種類與目前內容。
- 提供向上、下、左、右微調的 accessibility action。
- 編輯 sheet 提供九宮格快速定位，讓無法精細拖曳的使用者可設定位置。
- 刪除是破壞性動作，且可在草稿中復原。
- 基準線不只依靠顏色；吸附時同時提供觸覺回饋與 VoiceOver 提示。

## 舊設定遷移

第一次讀取新配置且尚無 `ReaderOverlayLayout` 時執行一次性遷移：

- `readerHeaderFieldPositions` 中的可見欄位依左／中／右映射到頂部對應比例座標。
- `readerFooterVisible` 為真時，建立本章頁碼、總進度、時間與電量元件，位置接近目前頁腳左右配置。
- `readerHeaderTopPadding`、`readerHeaderHorizontalPadding`、`footerBottomPadding`、`readerFooterHorizontalPadding` 只用於計算遷移後的初始比例位置。
- 現有頁眉與頁腳對正文造成的頂部／底部保留量轉存到 `contentReservations`，確保遷移前後初始分頁幾何一致。
- 隱藏欄位不建立元件。
- 新配置成功保存後記錄遷移版本；舊 key 保留讀取能力，供舊排版匯入與降級相容使用。

在新配置已存在後匯入舊版排版檔時，只在該檔案明確包含頁眉／頁腳欄位時，將這些欄位轉成一組新元件並取代目前覆蓋層配置；其他閱讀排版欄位照既有流程匯入。匯入前沿用既有確認流程，避免靜默覆蓋使用者手動配置。

遷移必須可重複呼叫而不產生重複元件。

## 錯誤與回退

- 缺少字體：退回系統字體。
- 缺少或損壞 SVG：退回系統電池圖示。
- 無法保存：保留編輯草稿並顯示錯誤，不關閉編輯器。
- 視窗尺寸為零或尚未穩定：延後座標換算，不把元件保存到 `(0, 0)`。
- 元件配置解碼失敗：保留損壞檔案供診斷，載入遷移後的預設配置。
- 剩餘時間不可估算：顯示 `--`。

## 測試策略

先以 TDD 完成純邏輯，再接 UI：

- 正規化座標在不同視窗比例、旋轉與安全區下正確換算。
- 元件 frame 永遠完整留在畫面內。
- 中心、邊緣、安全區與其他元件吸附僅在 6pt 內生效，且每軸選最近候選。
- 舊設定遷移結果正確且具冪等性。
- 元件內容格式、日期、星期、閱讀時長與剩餘時間回退正確。
- SVG 安全驗證拒絕禁止元素、事件與外部資源。
- SVG 動態角色正確更新電量、百分比與充電圖層。
- 字體與 SVG 遺失時回退正確。
- 草稿取消不寫入；完成才原子保存；刪除可復原。
- 分頁閱讀顯示元件，捲動閱讀不顯示。

依專案規則，不由代理直接執行長時間 `xcodebuild`。完成實作後提供單一測試類別與必要 smoke build 指令，由使用者執行；代理仍會執行 Swift 語法解析、本地化同步及 `git diff --check`。

## 驗收條件

- 使用者可從閱讀設定進入「頁首頁尾編輯」。
- 現有可見頁眉／頁腳資料能遷移成可拖曳元件。
- 元件能在整個畫面內自由移動、覆蓋正文並保持完整可見。
- 吸附時顯示正確基準線並提供一次觸覺回饋。
- 點元件可編輯或刪除；取消不保存，完成才保存。
- 所有確認的資訊種類可新增並正確更新。
- 每元件可獨立設定字體、大小、粗細、顏色與透明度。
- 動態 SVG 電量模板可安全匯入、預覽、套用與分享。
- 版面在不同裝置與方向下依比例適配。
- 拖曳與樣式修改不觸發 CoreText 重新分頁。
