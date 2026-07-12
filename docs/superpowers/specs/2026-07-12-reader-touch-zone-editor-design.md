# Reader 3×3 Touch Zone Editor Design

## Goal

Add a Yuedu Pro-only editor that lets readers assign actions to a 3×3 tap grid while viewing the real reading surface. The saved grid becomes the source of truth for tap navigation in paged readers.

## Access and entitlement behavior

- Add a `翻頁區塊編輯` row to reader settings only when `SubscriptionStore.isProActive` is true.
- Free users do not see a locked row or another discovery surface for this editor.
- Opening and applying the editor both check the active Pro entitlement.
- If Pro access lapses, keep the saved configuration on disk but ignore it at runtime and use `TouchZoneConfig.default`. Restoring Pro access makes the saved configuration available again.
- Other Pro feature listings may continue to advertise `PremiumFeature.touchZoneEditor` through the existing subscription UI.

## Entry and presentation

- The editor starts from reader settings.
- Selecting the row dismisses the settings sheet, then presents a full-screen editing overlay above the current reading surface.
- The overlay dims the current page while preserving enough contrast to show where each zone lands on real content.
- A header uses the localized title `翻頁區塊編輯`, a leading `xmark` to cancel, and a trailing `checkmark` to save. Modal toolbar conventions and accessibility labels follow the project design guide.
- A 3×3 grid fills the tappable reading area. Each cell shows its assigned action and has visible boundaries, a minimum accessible hit target, and a VoiceOver label that includes its row, column, and action.
- A localized `恢復預設` control resets the draft to `TouchZoneConfig.default` without saving immediately.

## Editing interaction

- Entering the editor copies the effective saved configuration into draft state.
- Tapping a cell presents a native SwiftUI action menu for that cell.
- The menu offers these actions in this order:
  1. `無動作`
  2. `選單`
  3. `上一頁`
  4. `下一頁`
  5. `上一章`
  6. `下一章`
  7. `添加/移除書籤`
  8. `目錄`
- Choosing an action updates only the draft cell and immediately updates its label.
- Cancel discards all draft changes. Save validates that the grid contains exactly nine actions, persists it, disables `全局翻頁`, and closes the overlay.

## Default grid

Indices remain row-major from top-left to bottom-right:

| Row | Left | Center | Right |
| --- | --- | --- | --- |
| Top | 上一頁 | 上一頁 | 下一頁 |
| Middle | 上一頁 | 選單 | 下一頁 |
| Bottom | 上一頁 | 下一頁 | 下一頁 |

## Data model and persistence

- Extend `TouchAction` with previous chapter, next chapter, bookmark toggle, and table-of-contents actions.
- Preserve the existing raw values for current cases so previously saved data continues to decode.
- Keep the current `yd_touch_zones` storage key and JSON persistence format.
- Centralize validation and safe indexing in `TouchZoneConfig`; malformed data, a non-nine-element grid, zero-sized surfaces, and out-of-bounds touch coordinates fall back safely instead of trapping.
- Add an entitlement-aware resolver that returns the saved grid for Pro users and the default grid for free users. UI visibility and runtime application must not rely on separate ad hoc entitlement rules.

## Reader integration

- Replace the hard-coded horizontal left/center/right tap calculation with the shared 3×3 `TouchZoneConfig` lookup.
- Keep physical touch coordinates stable in both LTR and RTL layouts. The configured action is explicit, so RTL must not silently swap `上一頁` and `下一頁`.
- Route actions through a shared reader action type or handler so CoreText paged reading and fixed-layout paged reading behave consistently.
- Page actions call the existing previous/next-page paths.
- Chapter actions call the existing previous/next-chapter paths and retain their current boundary behavior.
- Menu toggles the reader chrome. Table of contents opens the existing TOC surface. Bookmark action toggles the current reading position using the existing bookmark path.
- `無動作` consumes the tap without navigation or opening the menu.
- Swipe gestures, scroll mode, footnote taps, text selection, and other reader gestures remain unchanged.
- The editor entry is hidden while scroll mode is active because the grid controls paged-reader taps only.

## Interaction with global page turning

- `全局翻頁` remains available as an existing quick behavior.
- Saving any custom grid automatically sets `readerTapBothSidesNextPage` to false.
- Once a custom grid is saved, tap routing uses the grid and does not apply the global left/right override.
- Changing `全局翻頁` later does not delete the saved grid. Turning it on temporarily uses the existing global behavior; turning it off restores the saved Pro grid.
- The editor displays the saved grid rather than the temporary global override.

## Localization and visual design

- Every new visible string uses `localized()` and is synchronized across `zh-Hant`, `zh-Hans`, and `en` resources.
- Reuse existing localization keys where their meaning is identical.
- Use `DSColor`, `DSFont`, and `DSSpacing`; do not copy the reference app's colors, typography, or dialog styling.
- Use native SwiftUI menus, materials, controls, animation, and accessibility behavior.

## Testing and verification

Implementation follows test-driven development. Focused tests cover:

- All nine normalized grid coordinates, including cell boundaries.
- Safe behavior for zero-size surfaces and clamped out-of-range coordinates.
- Round-trip encoding of every `TouchAction` and compatibility with existing four-action payloads.
- Invalid persisted grids falling back to defaults.
- Pro users resolving the saved configuration and free users resolving the default configuration.
- Free users not seeing the editor entry and Pro users seeing it in `ReaderPremiumVisibilityPolicy`.
- Mapping each action to the correct reader command.
- Saving a custom grid disabling global page turning while preserving the saved grid.
- Localization key parity across all three language files.

Per repository instructions, verification uses targeted source inspection, parse/localization checks, and focused test code review. The user will run any requested long `xcodebuild` command separately.

## Out of scope

- Resizable or non-rectangular zones.
- Per-book or per-reading-mode grids.
- Custom swipe gestures.
- Reordering the action menu.
- Exposing the editor to free users as a preview or locked row.
