# SwiftUI data flow and rendering cost

## Mental model

Each `View` struct is an invalidation boundary. With `ObservableObject`, a view that
observes an object re-runs `body` on **any** `@Published` change in it. With
`@Observable` (iOS 17+), a view re-runs only when a stored property it actually read
changes; reading a computed property subscribes to every stored property its getter
touches, and reading a stored struct subscribes to the whole struct.

`GlobalSettings` is `@Observable` (since 2026-10-10; it had 137 `@Published` observed in
~600 places, and a brightness tick re-rendered the root, the reader and the shelf). Views
hold it as `@Bindable private var gs = GlobalSettings.shared`. Things views draw that are
not stored settings need an explicit dependency: fonts come from `GlobalAppTypography`
statics, so its builders read `GlobalSettings.typographyRevision`; themes come from the
`appThemes` environment value, never the `AppearanceThemePreset.activeAppThemes` global;
a setting stored outside the class (UserDefaults-backed computed property) calls
`access(keyPath:)` / `withMutation(keyPath:)`. There is no `objectWillChange` and no
`$property` publisher: non-view observers use `withObservationTracking`, reading the new
value after hopping to the main actor (the callback fires before the change lands, once).
Tests use `ObservationRecorder`. Most other stores are still `ObservableObject`.

## Rules with project examples

**Observation scope**
- New shared state: `@MainActor @Observable final class`. Own with `@State private var`,
  pass with `let`, bind with `@Bindable`.
- Migrating an existing `ObservableObject`: first grep for `$property` publishers and
  `objectWillChange` subscribers (for `GlobalSettings`: `FirestoreSyncManager.swift:287`,
  `ICloudSyncManager.swift:424`); `@ObservedObject private var gs = GlobalSettings.shared`
  becomes `private let gs = GlobalSettings.shared`.
- Shared modifiers/rows/covers take the values they read as parameters.
- Delete observed properties a view never reads (each still subscribes).
- Don't declare `@EnvironmentObject` only to re-inject it; SwiftUI sheets and
  `navigationDestination` inherit environment objects. Only UIKit hosting boundaries
  (e.g. `ReaderHostingController`) need manual injection.

**Body and init cost**
- `body` runs often; `init` runs on every parent body. Neither does I/O, JSON, JS, store
  lookups, image decode, or full-collection filter/sort.
- Derive once, at the owner's write point: shelf pages/groups/sorted entries in the
  bookshelf model, enabled sources and an id index in `BookSourceStore`, per-feed sorted
  articles and unread counts in `RSSStore`. `BookStore.books` is a `records.filter` per
  access — read it once per body at most, preferably not at all.
- Don't build export documents, formatters, or images in `body`. Formatters are
  `static let` or `Text(value, format:)`; never a stored property of a View struct.
- Pass rows small value inputs; `ReadingBook` (40 fields, not `Equatable`) plus closures
  prevents SwiftUI from skipping unchanged rows.

**High-frequency values**
- Never write scroll offset / geometry / drag / slider / playback position into `@State`
  of a large view or into the environment on every frame.
  - Threshold: `.onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 0 } action: { heroHidden = $0 }`.
  - Appearance only: `scrollTransition` / `visualEffect` (no body re-run).
  - Frame needed only on tap (open-book zoom): use a UIKit anchor read on demand
    (`PublicLibraryCoverFrames`) — not a `.global` GeometryReader + preference per cell
    (`HomeView.reportBookshelfCoverFrame` is the anti-pattern).
  - Sliders: drag into local `@State`, commit to `GlobalSettings` in `onEditingChanged(false)`.
- Callbacks that fire per TTS segment / per chapter / per frame assign only changed values
  (`NowPlayingHub.update(from:)` re-renders the root per sentence today).

**Environment**
- No closures or per-frame values in environment keys (`BookDetailCardChrome`,
  `PublicLibrarySheetContext`, `OpenPublicLibraryBooksKey` are current offenders). Inject a
  stable `@Observable` model; actions are its methods.
- New keys: `@Entry` with a stable default (`static let`, `nil`, or a literal).

**Lists**
- Identity from the element's stable id; never `.indices`, `\.offset`, `UUID()` in body,
  or `id: \.self` on a large struct.
- Constant view count/kind per element; no top-level `if`/`switch` in a row (wrap in a
  container); filter before `ForEach`. Debug with launch argument `-LogForEachSlowPath YES`.
- `LazyVStack`/`List` for anything that can grow (`RSSListView` uses an eager `VStack`).
- Cell work goes in `.task(id:)` so it cancels when the cell scrolls away.

**Presentation and navigation**
- Optional-driven content: `.sheet(item:)` / `.fullScreenCover(item:)` with an
  `Identifiable` route. Optional-driven alerts/dialogs: the `item:` forms, not
  `Binding(get: { x != nil }, set: …)`.
- A path-driven stack uses only `NavigationLink(value:)`.
- iOS 17 menu → modal: `DismissalSequencedActionChooser` (see `Technotes/iOS17MenuModalPresentation.md`).
- Search results: freeze the snapshot into the route (see `Technotes/iOS17SearchWatchdogPostmortem.md`).

**Modern API at an iOS 17 floor** (only when already editing the line; never a drive-by)
- `foregroundStyle`, `clipShape(.rect(cornerRadius:))`, `.tint`, `.topBarLeading/Trailing`,
  `Task.sleep(for:)`, `@Entry`, `#Preview`, `onChange(of:) { old, new in }`, `.animation(_:value:)`.
- Keep `tabItem` (`Tab` is iOS 18) and `Array(x.enumerated())` (direct is iOS 26).
- `AnyView` only where the type checker forces it.

## Debugging an over-updating view

- `let _ = Self._logChanges()` in `#if DEBUG` (iOS 17+, logs to `com.apple.SwiftUI`,
  category "Changed Body Properties") shows which input invalidated the body.
- On a real device, the SwiftUI Instruments template shows update counts and the cause
  graph; the Simulator leaves the SwiftUI lane empty.
