# Yuedu Library Services

Paths below are relative to the repository root. Read only the section relevant to the task.

## Bookshelf And Persistence

- `BookStore.books` is `@Published [ReadingBook]`; order is insertion/order state.
- Sorting changes should go through `BookStore.moveBooks(ids:before:)`, which saves metadata.
- Delete books through `BookStore.delete(bookId:)`; it clears cache directories and font resources.
- Cover files live under Documents and are referenced by `book.coverImagePath`.
- Bookmarks should not use `globalPage` or legacy `pageIndex` as stored identity. `Bookmark.position` is `CoreTextReadingPosition(spineIndex, charOffset)`; sorting, deduplication, and jumps should use that stable position.
- The top-bar bookmark currently means a chapter-start bookmark. Use `.chapterStart(chapterIndex)` for its toggle/check state; bookmark-list jumps should use the bookmark's own `charOffset`.
- Preserve legacy bookmark decode fallback. `Bookmark.CodingKeys` still includes `pageIndex`, `spineIndex`, and `charOffset` so older metadata can migrate.
- For new per-book settings, add a Codable field to `ReadingBook`, handle decode defaults, add a `BookStore.set...` method, and call `saveMeta()`.


## Account Sign-In

- Account state is currently stored in `GlobalSettings.shared`: `isLoggedIn`, `accountDisplayName`, `accountEmail`, `accountProvider`, and `accountAvatarData`, all persisted through `UserDefaults`.
- The settings entry point is `Modules/Features/Settings/ProfileView.swift` (`SettingsView`) -> `UserDetailView`; `LoginView` lives under `Modules/Features/Settings/LoginView.swift`. Do not put sign-in UI under `Modules/Features/Reader/TTS/`; that folder is for reader text-to-speech UI.
- Sign-out must go through `GlobalSettings.signOut(...)`; do not mutate `isLoggedIn` directly from views. Google accounts need to clear `GIDSignIn.sharedInstance` first: normal sign-out uses `signOut()`, while revoke uses the `disconnect` path.
- On successful sign-in, `LoginView` should call its success callback and `dismiss()` so the parent sheet binding and actual presentation state stay in sync.
- Avatar changes use `PhotosPicker` -> resize/compress -> `GlobalSettings.updateAccountAvatar(data:)`. `ProfileView` and `UserDetailView` should share the same account avatar rendering instead of duplicating state.
- Google Sign-In has three required app-side pieces: `Info.plist` `GIDClientID` plus URL scheme, `project.pbxproj` package products for `GoogleSignIn` and `GoogleSignInSwift`, and the `google_logo` asset.
- Downloaded `client_*.plist` OAuth config files are not read automatically unless the Xcode project references them or code loads them. Before committing one, verify it is actually needed.


## RSS

- `RSSFetcher` is `@MainActor final class`; keep `@Published` state updates on the main actor.
- Keep the explicit `URLRequest` timeout, `.reloadIgnoringLocalCacheData`, and `Mozilla/5.0` User-Agent. Some feeds reject the default URLSession user agent.
- `RSSXMLParser` handles RSS and Atom. Lowercase element names, read Atom `<link href="">` only for `rel="alternate"` or empty rel, support `description`, `summary`, `content`, and `content:encoded`, and append CDATA text.
- Treat parser errors and empty feeds separately. Parser errors should clear `items`; successful empty feeds should show an empty state with reload.
- For RSS article rendering, mirror NetNewsWire's body strategy: parser records keep raw `contentHTML`; the article reader sanitizes it and renders the sanitized HTML body. Avoid `NSAttributedString(data: .html)` in SwiftUI rows, and avoid reparagraphing already-structured article HTML in the reader.
- The RSS reader template should stay close to NetNewsWire's `ArticleRenderer` + `template.html` + iOS `page.html` + `stylesheet.css`: feed/source header, optional icon, linked article title, dateline, and a body container that receives already-sanitized HTML.
- Treat inline tags such as `<a>`, `<strong>`, `<em>`, `<span>`, and `<code>` as part of their parent paragraph. Never promote an inline link into its own paragraph; that creates broken text such as a phrase before the link and the linked phrase appearing as separate paragraphs.
- Only synthesize paragraphs for true plain-text fallback or HTML with no usable block structure. In fallback mode, split explicit blank lines first; sentence/length splitting is a last resort.
- Remove article noise before rendering or extraction with precise selectors/text checks: dangerous tags, ad/noise DOM nodes, and standalone ad labels such as `廣告`, `广告`, or `Advertisement`. Do not delete broad substrings from normal body text.
- Reader View/full-text extraction is a separate step from feed rendering. NetNewsWire gets cleaned `ExtractedArticle.content` from Mercury/Feedbin and then injects that content directly; local extraction should likewise output cleaned HTML plus plain text, not a lossy plain-text-only body.
