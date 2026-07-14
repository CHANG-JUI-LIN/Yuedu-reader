# Reader Overlay Page Scopes and UI Audit Design

## Goal

Refine the reader header/footer editor so chapter-opening pages and chapter-body pages own independent component arrangements, snapping is stable and limited to meaningful typography guides, and every overlay-related screen follows the existing Yuedu DS tokens and native iOS interaction conventions. Publish matching Traditional Chinese and English documentation for battery SVG templates.

## Terminology

- **Chapter opening (`chapterOpening`)**: the first rendered page inside a chapter (`pageInChapter == 0`, exposed to overlay content as chapter page 1).
- **Chapter body (`chapterBody`)**: every later rendered page in the same chapter.
- **Body frame**: the rectangle occupied by paginated body text after applying the current horizontal page margin plus the shared top and bottom content reservations.
- **Peer guide**: the minimum edge, center, or maximum edge of another overlay component on the currently edited page scope.

## Data Model and Migration

`ReaderOverlayLayout` advances to version 2 while retaining the existing `components` JSON field as the chapter-body component array. It adds `chapterOpeningComponents` for chapter-opening pages. Retaining `components` avoids breaking version-1 presets and external JSON already produced by the app.

The in-memory API exposes explicit scope accessors so UI and runtime code do not rely on the compatibility field name:

- `components(for: .chapterOpening)`
- `components(for: .chapterBody)`
- a mutation helper that replaces the array for one scope

When version-1 data or a payload without `chapterOpeningComponents` is decoded, the normalized body components are copied into the opening array, as selected by the user. Both arrays then evolve independently. Component UUIDs must be unique inside each scope; the same UUID may exist in both scopes because migration begins with a value copy and editor selection is scope-local.

`contentReservations` remains shared between both scopes. Per-page reservations would make a single chapter paginate with changing geometry and are outside this change.

New JSON export/import preserves both arrays. Existing import priority remains:

1. valid current overlay JSON;
2. migrated fixed header/footer fields;
3. keep the current overlay when neither exists.

Malformed version-2 fields fall back through the existing safe migration path rather than clearing either scope.

## Runtime Selection

The runtime canvas selects `.chapterOpening` when the current overlay snapshot reports chapter page 1; otherwise it selects `.chapterBody`. This rule is shared by TXT, online books, reflowable EPUB, and fixed-layout EPUB. Scroll mode continues to hide fixed overlays.

Opening the editor chooses the scope matching the currently visible page. Switching the editor segment changes only the previewed and edited overlay array; it never navigates the book or changes `(spineIndex, charOffset)`.

## Editor Surface

The reader content remains full-screen behind the overlay components. The current top toolbar and full-width bottom action are replaced by a centered floating control stack modeled on the supplied reference:

1. a native segmented picker labeled `首頁` and `正文`;
2. a material capsule button labeled `新增組件` with the `plus` symbol;
3. a material capsule button labeled `退出編輯` with a downward chevron.

The controls use DS fonts, spacing, sizes, borders, and animations. Each interactive row keeps a minimum 44-point hit region. The stack avoids selected components and safe areas through the existing editor geometry helpers, and it remains readable in Light, Dark, Increase Contrast, and themed reader backgrounds.

`退出編輯` behaves as follows:

- no changes: dismiss immediately;
- changed draft: present a native confirmation dialog with `儲存並退出`, `不儲存退出`, and `繼續編輯`;
- save failure: keep the editor open and display a localized error;
- cancel/discard restores the original two-scope layout.

The delete undo affordance remains a transient material capsule above the central stack. Selecting an existing component continues to expose native edit and delete actions.

## Stable Snapping and Guides

Snapping targets are intentionally limited to:

- body frame top and bottom;
- body frame left and right margins;
- peer component minimum edge, center, and maximum edge on each axis.

Canvas edges, safe-area edges, and standalone screen center lines are not independent snap targets unless they coincide with a body-frame line.

The engine keeps an independent X-axis and Y-axis latch for the duration of one drag:

- acquire the nearest target inside 6 points;
- retain the latched target until the dragged alignment moves more than 12 points from it;
- while latched, do not switch to another candidate on the same axis;
- when candidates tie during acquisition, prefer body-frame boundaries, then peer centers, then peer edges;
- clamp the final component center to the canvas after applying the two axis latches;
- clear latches and visible guides when the drag ends.

The two distances become `DSLayout` tokens. A guide appears only for a currently latched target. Haptic feedback and repeated alignment announcements are removed so the interaction does not feel like it is vibrating or oscillating. VoiceOver users retain directional nudge and nine-position placement actions.

The editor receives the actual body frame derived from the same horizontal margin and content reservations used for pagination. Tests must ensure overlay component positions and styles never affect that frame.

## Add and Edit Component Flows

### Add Component

The add screen is a native modal `NavigationStack` containing an inset-grouped `List`:

- inline navigation title;
- leading `xmark` with localized accessibility label;
- semantic SF Symbol and one localized component name per row;
- categories remain Basic, Progress, Time, Status, and Statistics;
- rows use at least a 44-point hit region;
- themed background and row backgrounds use explicit DS surface tokens so no accidental white section appears;
- selecting a row adds the component only to the active page scope and dismisses the sheet.

### Edit Component

The edit screen uses a native `Form` inside a modal `NavigationStack`:

- leading `xmark` discards unconfirmed field edits;
- trailing `checkmark` commits the local component draft to the active scope;
- inline title and DS typography;
- native `Picker`, `Toggle`, `Slider`, `ColorPicker`, and navigation rows;
- imported-font and SVG navigation use semantic secondary text and chevrons;
- missing font or SVG assets visibly fall back to the system representation.

## Overlay UI Audit Scope

The audit covers only pages introduced for this reader overlay feature:

- `ReaderHeaderFooterEditorView`
- `ReaderOverlayComponentPickerView`
- `ReaderOverlayComponentEditView`
- `ReaderOverlayFontPickerView`
- `ReaderBatterySVGImportView` and SVG asset rows
- related sheets, confirmation dialogs, empty states, error states, and accessibility actions

Every screen is checked against `docs/design.md` and `yuedu-ios-design`:

- existing `DSColor`, `DSFont`, `DSSpacing`, `DSLayout`, `DSRadius`, and `DSAnimation` tokens only;
- add a token centrally when a genuinely reusable value is missing;
- all visible strings localized in zh-Hant, zh-Hans, and English;
- modal `xmark`/`checkmark` conventions;
- Dynamic Type, VoiceOver labels/order, 44-point hit regions, Reduce Motion, and non-color-only state;
- native list/form/sheet behavior;
- continuous themed backgrounds for content, empty, loading, and error rows;
- no hard-coded colors, fonts, spacing, corner radii, or animation durations in feature views.

## Battery SVG Documentation

Create two equivalent documents:

- `docs/reader-overlay/BatterySVG.zh-Hant.md`
- `docs/reader-overlay/BatterySVG.en.md`

Each document describes:

- supported `.svg` encoding, file-size, dimensions, and `viewBox` expectations;
- the required `data-yuedu-role="battery-level"` element;
- optional `data-yuedu-role="battery-percent"` visibility behavior;
- `data-yuedu-direction` values: `left-to-right`, `right-to-left`, `bottom-to-top`, and `top-to-bottom`;
- foreground/color replacement rules and supported color syntax;
- supported elements and attributes;
- rejected scripts, event handlers, document types, external URLs, unsafe CSS, and external references;
- how missing or deleted assets fall back to the system battery icon;
- import, selection, rename, export, and deletion behavior;
- minimal horizontal and vertical fill examples that pass the production parser.

The documentation must be derived from `ReaderBatterySVGTemplate.swift` and its tests rather than describing unsupported generic SVG features.

## Testing and Verification

Tests are added or updated before production changes for:

- version-1 layout migration clones body into opening;
- version-2 encode/decode preserves two independent arrays;
- normalization and duplicate-ID validation operate per scope;
- runtime scope selection uses chapter page 1 for opening and later pages for body;
- editor add, edit, move, delete, and undo affect only the active scope;
- snap acquisition uses body edges and peer alignment targets only;
- each axis remains latched inside the release distance and switches only after release;
- unrelated canvas/safe-area/center targets do not snap;
- body frame calculation matches pagination margins and reservations;
- malformed imported layouts cannot erase either scope.

Static verification includes Swift parsing of every touched source, `ruby scripts/check_localizations.rb`, `plutil -lint` for all three localization files, and `git diff --check`. Per repository instruction, the user runs the focused `xcodebuild` test commands.

## Non-Goals

- Per-book overlay layouts.
- Separate content reservations for opening and body pages.
- Fixed overlays in scroll mode.
- Arbitrary SVG scripting, animation, external resources, or web content.
- A whole-app design audit outside the overlay feature.
