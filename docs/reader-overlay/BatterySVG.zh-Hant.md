# 閱讀頁電量 SVG 模板規格

本規格適用於 Yuedu 閱讀頁「電量」組件匯入的 `.svg` 模板。模板會先經安全驗證及正規化，再保存在 App 內；不符合規格的檔案不會匯入。

## 快速開始

一個可隨電量變化的模板至少需要：

- UTF-8 編碼的 `.svg` 檔案，大小不超過 256 KiB（262,144 bytes）。
- 單一 `<svg>` 根元素。
- 有效的 `viewBox`；或可轉成 `viewBox` 的正數 `width` 與 `height`。
- 一個帶有 `data-yuedu-role="battery-level"` 的圖形元素。
- 動態顏色使用 `currentColor`。

最小範例：

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40">
  <rect width="100" height="40" rx="6" fill="none" stroke="currentColor" stroke-width="4"/>
  <rect data-yuedu-role="battery-level" data-yuedu-direction="left-to-right"
        x="6" y="6" width="88" height="28" rx="3" fill="currentColor"/>
</svg>
```

## 座標系統與資源限制

建議直接提供 `viewBox="minX minY width height"`。四個值必須是有限數字，且 `width`、`height` 必須大於 0。

若沒有 `viewBox`，根元素必須同時提供 `width` 與 `height`。這兩個值只接受：

- 正數，例如 `120`、`48.5`；
- 正數加 `px`，例如 `120px`。

百分比、`cm`、`em` 等單位不接受。匯入後 App 會補上 `viewBox="0 0 width height"`。

其他上限：

| 項目 | 上限 |
| --- | --- |
| UTF-8 原始檔大小 | 256 KiB（262,144 bytes） |
| XML 巢狀深度 | 64 層，包含根元素 |
| 元素與文字節點總數 | 10,000 |

## 動態標記

### 電量填充

`data-yuedu-role="battery-level"` 標記會被目前電量的裁切區域包住。若沒有這個標記，SVG 仍可能通過安全驗證，但只會顯示靜態圖案，不會隨電量填充；因此功能完整的電量模板必須提供它。

此標記只可放在以下元素：

`g`、`path`、`rect`、`circle`、`ellipse`、`line`、`polyline`、`polygon`

可用 `data-yuedu-direction` 指定填充方向：

| 值 | 行為 |
| --- | --- |
| `left-to-right` | 從左向右，預設值 |
| `right-to-left` | 從右向左 |
| `bottom-to-top` | 從下向上 |
| `top-to-bottom` | 從上向下 |

`data-yuedu-direction` 必須與 `battery-level` 放在同一元素。模板可有多個 `battery-level`，但它們的方向必須一致；不同方向會使匯入失敗。

### 百分比文字

在 `<text>` 或 `<tspan>` 上使用：

```xml
data-yuedu-role="battery-percent"
```

顯示時，該元素的全部子內容會替換成四捨五入後的 `0%` 至 `100%`。不需要百分比時，省略此元素即可。

### 充電狀態

任何一般圖形或文字元素可使用：

```xml
data-yuedu-visible="charging"
```

該元素只在充電時保留，未充電時會移除。目前只支援 `charging`，不支援其他可見條件。

動態標記不可放在根 `<svg>`，也不可放在 `defs`、`clipPath`、`mask`、`linearGradient` 或 `radialGradient` 等資源定義內。

## 顏色

App 會在顯示時將元件顏色寫入根 `<svg>` 的 `color` 屬性，格式為 `#RRGGBBAA`。要讓圖案跟隨閱讀頁組件顏色，請在 `fill`、`stroke` 或漸層 `stop-color` 使用 `currentColor`。

建議使用：

- `currentColor`：跟隨組件顏色；
- `none`：不填色或不描邊；
- 固定十六進位顏色，例如 `#FFFFFF` 或 `#FFFFFFFF`。

固定色會原樣保留，不會被 App 替換。安全驗證器不會替你修正錯誤的 CSS 顏色，因此分享模板時以 `currentColor` 與十六進位顏色最穩定。

## 支援的 SVG 子集

### 元素

`svg`、`g`、`defs`、`clipPath`、`mask`、`path`、`rect`、`circle`、`ellipse`、`line`、`polyline`、`polygon`、`text`、`tspan`、`linearGradient`、`radialGradient`、`stop`、`title`、`desc`

### 屬性

支援下列屬性；其他屬性會使匯入失敗：

```text
id class version xmlns xmlns:xlink xml:space viewBox
x y x1 y1 x2 y2 cx cy r rx ry width height d points pathLength transform
preserveAspectRatio opacity fill fill-opacity fill-rule stroke stroke-width
stroke-opacity stroke-linecap stroke-linejoin stroke-miterlimit stroke-dasharray
stroke-dashoffset clip-path clip-rule clipPathUnits mask maskUnits maskContentUnits
gradientUnits gradientTransform spreadMethod offset stop-color stop-opacity
href xlink:href color style font-family font-size font-weight font-style
text-anchor dominant-baseline alignment-baseline baseline-shift letter-spacing
word-spacing paint-order vector-effect visibility display shape-rendering
text-rendering color-interpolation data-yuedu-role data-yuedu-visible
data-yuedu-direction
```

`href`、`xlink:href` 與 `url(...)` 只可引用同一份 SVG 內的 `#id`。

### 行內 style

允許分號分隔的簡單 `property: value`。支援的屬性為：

```text
opacity fill fill-opacity fill-rule stroke stroke-width stroke-opacity
stroke-linecap stroke-linejoin stroke-miterlimit stroke-dasharray stroke-dashoffset
clip-path clip-rule mask color font-family font-size font-weight font-style
text-anchor dominant-baseline alignment-baseline baseline-shift letter-spacing
word-spacing paint-order vector-effect visibility display shape-rendering
text-rendering stop-color stop-opacity
```

不接受選擇器、`@import`、大括號、`expression(...)` 或外部資源。

## 安全限制

以下內容會被拒絕：

- `DOCTYPE`、實體宣告、處理指令或多個根元素；
- `script`、`foreignObject`、`iframe`、`object`、`embed`、`animate`、`filter`、`image` 等未列入白名單的元素；
- `onclick` 等任何 `on...` 事件屬性，或未列入白名單的屬性；
- `javascript:`、`http:`、`https:`、`data:`、`file:`、`ftp:`、`//` URL；
- 外部 `href`、外部 `url(...)`、CSS 跳脫 URL、註解式隱藏 URL；
- 不受支援的命名空間元素、未知的 Yuedu 標記與未知填充方向。

## 完整橫向範例

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 48">
  <title>Horizontal battery</title>
  <rect x="2" y="2" width="104" height="44" rx="8"
        fill="none" stroke="currentColor" stroke-width="4"/>
  <rect x="108" y="15" width="10" height="18" rx="3" fill="currentColor"/>
  <rect data-yuedu-role="battery-level" data-yuedu-direction="left-to-right"
        x="8" y="8" width="92" height="32" rx="4" fill="currentColor"/>
  <text data-yuedu-role="battery-percent" x="54" y="31"
        fill="currentColor" font-size="14" text-anchor="middle">0%</text>
  <path data-yuedu-visible="charging" d="M58 7 L45 25 H56 L51 41 L73 19 H62 Z"
        fill="currentColor"/>
</svg>
```

## 完整縱向範例

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 120">
  <title>Vertical battery</title>
  <rect x="2" y="12" width="44" height="106" rx="8"
        fill="none" stroke="currentColor" stroke-width="4"/>
  <rect x="15" y="2" width="18" height="8" rx="3" fill="currentColor"/>
  <rect data-yuedu-role="battery-level" data-yuedu-direction="bottom-to-top"
        x="8" y="18" width="32" height="92" rx="4" fill="currentColor"/>
  <text data-yuedu-role="battery-percent" x="24" y="67"
        fill="currentColor" font-size="12" text-anchor="middle">0%</text>
</svg>
```

## App 內管理方式

1. 在電量組件的編輯頁選擇「SVG 模板」，再開啟模板清單。
2. 按右上角加號或「匯入 SVG」選取檔案。只有 UTF-8 且通過上述安全驗證的內容會寫入儲存區。
3. 選取模板後，該電量組件會記住模板 ID。重新匯入內容完全相同的模板會沿用既有項目，不會建立重複項目。
4. 從每列的更多選單可重新命名、分享正規化後的 `.svg`，或刪除模板。名稱會移除控制字元、換行及 `/\\:`，合併多餘空白，並限制為 80 個字元。
5. 刪除仍在使用的模板前，App 會警告使用者。刪除後，引用該模板的元件會自動改顯示系統電池圖示。

若檔案遺失、損毀、驗證版本不相容，或模板 ID 不存在，閱讀頁也會安全回退到系統電池圖示。重新匯入相同且有效的內容可修復缺少的檔案。

## 疑難排解

- **沒有跟著電量填充**：確認圖形元素含 `data-yuedu-role="battery-level"`，且標記不在 `defs` 內。
- **方向不正確**：只使用表格列出的四個完整值；同一模板的所有填充標記方向要一致。
- **顏色沒有跟著設定**：將固定 `fill`／`stroke` 改為 `currentColor`。
- **百分比沒有更新**：標記必須位於 `<text>` 或 `<tspan>`。
- **匯入失敗**：移除腳本、事件、外部 URL、未支援元素／屬性，並檢查 `viewBox`、檔案大小與 UTF-8 編碼。
