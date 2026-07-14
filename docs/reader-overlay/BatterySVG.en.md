# Reader Battery SVG Template Specification

This specification applies to `.svg` templates imported for Yuedu's reader battery component. A template is safety-validated and normalized before the app stores it. Files outside this subset are not imported.

## Quick start

A battery template that changes with the device level needs:

- A UTF-8 `.svg` file no larger than 256 KiB (262,144 bytes).
- One `<svg>` root element.
- A valid `viewBox`, or positive `width` and `height` values that can produce one.
- A graphic element marked with `data-yuedu-role="battery-level"`.
- `currentColor` wherever artwork should follow the component color.

Minimal example:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 40">
  <rect width="100" height="40" rx="6" fill="none" stroke="currentColor" stroke-width="4"/>
  <rect data-yuedu-role="battery-level" data-yuedu-direction="left-to-right"
        x="6" y="6" width="88" height="28" rx="3" fill="currentColor"/>
</svg>
```

## Coordinate system and resource limits

Prefer an explicit `viewBox="minX minY width height"`. All four values must be finite numbers, and `width` and `height` must be greater than zero.

Without a `viewBox`, the root must provide both `width` and `height`. Each value may be:

- A positive number such as `120` or `48.5`.
- A positive number followed by `px`, such as `120px`.

Percentages and units such as `cm` or `em` are rejected. The importer adds `viewBox="0 0 width height"` to the stored template.

Other limits:

| Item | Limit |
| --- | --- |
| UTF-8 source size | 256 KiB (262,144 bytes) |
| XML nesting depth | 64 levels, including the root |
| Total element and text nodes | 10,000 |

## Dynamic markers

### Battery fill

An element with `data-yuedu-role="battery-level"` is wrapped in a clipping region based on the current battery level. A static SVG without this marker can pass safety validation, but its artwork does not fill dynamically. A functional dynamic battery template therefore requires the marker.

The marker is valid only on:

`g`, `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`

Use `data-yuedu-direction` to choose a fill direction:

| Value | Behavior |
| --- | --- |
| `left-to-right` | Fill from left to right; this is the default |
| `right-to-left` | Fill from right to left |
| `bottom-to-top` | Fill from bottom to top |
| `top-to-bottom` | Fill from top to bottom |

`data-yuedu-direction` must be on the same element as `battery-level`. A template may have multiple level markers, but all of them must use the same direction. Conflicting directions reject the import.

### Percentage text

Place this marker on a `<text>` or `<tspan>` element:

```xml
data-yuedu-role="battery-percent"
```

At render time, all children of that element are replaced by the rounded value from `0%` through `100%`. Omit the element when percentage text is not wanted.

### Charging-only artwork

Any normal graphic or text element can use:

```xml
data-yuedu-visible="charging"
```

The element remains only while charging and is removed otherwise. `charging` is the only supported visibility condition.

Dynamic markers cannot be placed on the root `<svg>` or inside resource definitions such as `defs`, `clipPath`, `mask`, `linearGradient`, or `radialGradient`.

## Color behavior

At render time, the app writes the component color to the root `<svg>` as a `color` attribute in `#RRGGBBAA` form. Use `currentColor` in `fill`, `stroke`, or gradient `stop-color` to follow that color.

Recommended values are:

- `currentColor` to follow the component color.
- `none` for no fill or stroke.
- A fixed hexadecimal color such as `#FFFFFF` or `#FFFFFFFF`.

Fixed colors are preserved and are not replaced by the app. The safety validator does not repair invalid CSS color values, so `currentColor` and hexadecimal colors are the most portable choices for shared templates.

## Supported SVG subset

### Elements

`svg`, `g`, `defs`, `clipPath`, `mask`, `path`, `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `text`, `tspan`, `linearGradient`, `radialGradient`, `stop`, `title`, `desc`

### Attributes

Only the following attributes are accepted:

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

`href`, `xlink:href`, and `url(...)` may reference only an internal `#id` in the same SVG.

### Inline style

Simple semicolon-separated `property: value` declarations are allowed. Supported properties are:

```text
opacity fill fill-opacity fill-rule stroke stroke-width stroke-opacity
stroke-linecap stroke-linejoin stroke-miterlimit stroke-dasharray stroke-dashoffset
clip-path clip-rule mask color font-family font-size font-weight font-style
text-anchor dominant-baseline alignment-baseline baseline-shift letter-spacing
word-spacing paint-order vector-effect visibility display shape-rendering
text-rendering stop-color stop-opacity
```

Selectors, `@import`, braces, `expression(...)`, and external resources are rejected.

## Security restrictions

The importer rejects:

- `DOCTYPE`, entity declarations, processing instructions, or multiple roots.
- Non-allowlisted elements such as `script`, `foreignObject`, `iframe`, `object`, `embed`, `animate`, `filter`, and `image`.
- Any `on...` event attribute such as `onclick`, and any non-allowlisted attribute.
- `javascript:`, `http:`, `https:`, `data:`, `file:`, `ftp:`, and protocol-relative `//` URLs.
- External `href`, external `url(...)`, CSS-escaped URLs, and comment-obfuscated URLs.
- Namespaced elements, unknown Yuedu markers, and unknown fill directions.

## Complete horizontal example

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

## Complete vertical example

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

## Managing templates in the app

1. In the battery component editor, choose "SVG Template" and open the template list.
2. Use the top-right plus button or "Import SVG" to choose a file. Only UTF-8 content that passes the safety validation above is written to storage.
3. Selecting a template stores its asset ID in that battery component. Reimporting identical normalized content reuses the existing asset instead of creating a duplicate.
4. The More menu on a row can rename, share the normalized `.svg`, or delete it. Names have control characters, newlines, and `/\\:` removed; repeated whitespace is collapsed; and the result is limited to 80 characters.
5. The app warns before deleting a template that is still referenced. After deletion, affected components automatically display the system battery icon.

If a file is missing, corrupt, validated by an incompatible version, or referenced by an unknown asset ID, the reader also falls back safely to the system battery icon. Reimporting the same valid content can repair a missing stored file.

## Troubleshooting

- **The artwork does not fill with the battery level:** Ensure a supported graphic element has `data-yuedu-role="battery-level"` and is not inside `defs`.
- **The fill direction is wrong:** Use exactly one of the four documented values, consistently across all level markers.
- **The color does not follow the component setting:** Replace fixed `fill` or `stroke` values with `currentColor`.
- **The percentage does not update:** The marker must be on `<text>` or `<tspan>`.
- **Import fails:** Remove scripts, events, external URLs, unsupported elements or attributes, then check the `viewBox`, file size, and UTF-8 encoding.
