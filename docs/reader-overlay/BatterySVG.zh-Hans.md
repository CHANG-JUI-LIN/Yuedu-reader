# 阅读页电量 SVG 模板规范

本规范适用于 Yuedu 阅读页“电量”组件导入的 `.svg` 模板。模板会先经过安全验证和标准化，再保存在 App 内；不符合规范的文件不会导入。

## 快速开始

一个能随电量变化的模板至少需要：

- UTF-8 编码的 `.svg` 文件，大小不超过 256 KiB（262,144 bytes）。
- 单一 `<svg>` 根元素。
- 有效的 `viewBox`；或可转换为 `viewBox` 的正数 `width` 与 `height`。
- 一个带有 `data-yuedu-role="battery-level"` 的图形元素。
- 动态颜色使用 `currentColor`。

最小示例：

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40">
  <rect width="100" height="40" rx="6" fill="none" stroke="currentColor" stroke-width="4"/>
  <rect data-yuedu-role="battery-level" data-yuedu-direction="left-to-right"
        x="6" y="6" width="88" height="28" rx="3" fill="currentColor"/>
</svg>
```

## 坐标系统与资源限制

建议直接提供 `viewBox="minX minY width height"`。四个值必须是有限数字，且 `width`、`height` 必须大于 0。

如果没有 `viewBox`，根元素必须同时提供 `width` 与 `height`。这两个值只接受：

- 正数，例如 `120`、`48.5`；
- 正数加 `px`，例如 `120px`。

不接受百分比、`cm`、`em` 等单位。导入后 App 会补上 `viewBox="0 0 width height"`。

其他上限：

| 项目 | 上限 |
| --- | --- |
| UTF-8 原始文件大小 | 256 KiB（262,144 bytes） |
| XML 嵌套深度 | 64 层，包含根元素 |
| 元素与文本节点总数 | 10,000 |

## 动态标记

### 电量填充

`data-yuedu-role="battery-level"` 标记会被当前电量的裁剪区域包住。没有这个标记的 SVG 仍可能通过安全验证，但只能显示静态图案，不会随电量填充；因此功能完整的电量模板必须提供它。

该标记只能放在以下元素：

`g`、`path`、`rect`、`circle`、`ellipse`、`line`、`polyline`、`polygon`

可用 `data-yuedu-direction` 指定填充方向：

| 值 | 行为 |
| --- | --- |
| `left-to-right` | 从左向右，默认值 |
| `right-to-left` | 从右向左 |
| `bottom-to-top` | 从下向上 |
| `top-to-bottom` | 从上向下 |

`data-yuedu-direction` 必须与 `battery-level` 放在同一元素。模板可有多个 `battery-level`，但它们的方向必须一致；不同方向会导致导入失败。

### 百分比文本

在 `<text>` 或 `<tspan>` 上使用：

```xml
data-yuedu-role="battery-percent"
```

显示时，该元素的全部子内容会替换为四舍五入后的 `0%` 至 `100%`。不需要百分比时，省略此元素即可。

### 充电状态

任何普通图形或文本元素可使用：

```xml
data-yuedu-visible="charging"
```

该元素只在充电时保留，未充电时会移除。目前只支持 `charging`，不支持其他可见条件。

动态标记不可放在根 `<svg>`，也不可放在 `defs`、`clipPath`、`mask`、`linearGradient` 或 `radialGradient` 等资源定义内。

## 颜色

App 显示模板时会将组件颜色写入根 `<svg>` 的 `color` 属性，格式为 `#RRGGBBAA`。要让图案跟随阅读页组件颜色，请在 `fill`、`stroke` 或渐变 `stop-color` 中使用 `currentColor`。

建议使用：

- `currentColor`：跟随组件颜色；
- `none`：不填色或不描边；
- 固定十六进制颜色，例如 `#FFFFFF` 或 `#FFFFFFFF`。

固定颜色会原样保留，不会被 App 替换。安全验证器不会修正错误的 CSS 颜色，因此分享模板时以 `currentColor` 与十六进制颜色最稳定。

## 支持的 SVG 子集

### 元素

`svg`、`g`、`defs`、`clipPath`、`mask`、`path`、`rect`、`circle`、`ellipse`、`line`、`polyline`、`polygon`、`text`、`tspan`、`linearGradient`、`radialGradient`、`stop`、`title`、`desc`

### 属性

只支持以下属性；其他属性会导致导入失败：

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

`href`、`xlink:href` 与 `url(...)` 只能引用同一份 SVG 内的 `#id`。

### 行内 style

允许使用分号分隔的简单 `property: value`。支持的属性为：

```text
opacity fill fill-opacity fill-rule stroke stroke-width stroke-opacity
stroke-linecap stroke-linejoin stroke-miterlimit stroke-dasharray stroke-dashoffset
clip-path clip-rule mask color font-family font-size font-weight font-style
text-anchor dominant-baseline alignment-baseline baseline-shift letter-spacing
word-spacing paint-order vector-effect visibility display shape-rendering
text-rendering stop-color stop-opacity
```

不接受选择器、`@import`、大括号、`expression(...)` 或外部资源。

## 安全限制

以下内容会被拒绝：

- `DOCTYPE`、实体声明、处理指令或多个根元素；
- `script`、`foreignObject`、`iframe`、`object`、`embed`、`animate`、`filter`、`image` 等未列入白名单的元素；
- `onclick` 等任何 `on...` 事件属性，或未列入白名单的属性；
- `javascript:`、`http:`、`https:`、`data:`、`file:`、`ftp:`、`//` URL；
- 外部 `href`、外部 `url(...)`、CSS 转义 URL、注释式隐藏 URL；
- 不支持的命名空间元素、未知的 Yuedu 标记与未知填充方向。

## 完整横向示例

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

## 完整纵向示例

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

## App 内管理方式

1. 在电量组件编辑页选择“SVG 模板”，再打开模板列表。
2. 按右上角加号或“导入 SVG”选择文件。只有 UTF-8 且通过上述安全验证的内容才会写入存储区。
3. 选择模板后，该电量组件会记住模板 ID。重新导入内容完全相同的模板会沿用已有项目，不会创建重复项目。
4. 从每行的更多菜单可重命名、分享标准化后的 `.svg`，或删除模板。名称会移除控制字符、换行及 `/\\:`，合并多余空白，并限制为 80 个字符。
5. 删除仍在使用的模板前，App 会警告用户。删除后，引用该模板的组件会自动改为显示系统电池图标。

如果文件丢失、损坏、验证版本不兼容，或模板 ID 不存在，阅读页也会安全回退到系统电池图标。重新导入相同且有效的内容可修复丢失的文件。

## 疑难排查

- **没有随电量填充**：确认图形元素含 `data-yuedu-role="battery-level"`，且标记不在 `defs` 内。
- **方向不正确**：只使用表格列出的四个完整值；同一模板的所有填充标记方向必须一致。
- **颜色没有跟随设置**：将固定 `fill`／`stroke` 改为 `currentColor`。
- **百分比没有更新**：标记必须位于 `<text>` 或 `<tspan>`。
- **导入失败**：移除脚本、事件、外部 URL、未支持元素／属性，并检查 `viewBox`、文件大小与 UTF-8 编码。
