# Yuedu Module Map

Paths below are relative to the repository root. Read only the section relevant to the task.

## Area Map

| Task area | Main folders |
| --- | --- |
| Reading rendering, layout, fonts, margins, paging | `Modules/Core/ReaderCore/`, `Modules/Core/ReaderCore/CoreText/`, `Modules/Features/Reader/` |
| Bookshelf, book CRUD, grouping, drag sorting | `Modules/Services/LibraryStore/`, `Modules/Features/Bookshelf/` |
| Book sources, online books, rule engine | `Modules/Core/BookSource/`, `Modules/Services/Online/`, `Modules/Core/RuleEngine/`, `Modules/Features/BookSource/`, `Modules/Features/Explore/` |
| Global settings, themes, DI | `Targets/Yuedu/SharedApp/`, `Modules/SharedUI/DesignSystem/` |
| Account, sign-in, Google Sign-In, Apple Sign-In | `Modules/Services/Account/`, `Modules/Features/Settings/ProfileView.swift`, `Modules/Features/Settings/UserDetailView.swift`, `Modules/Features/Settings/LoginView.swift`, `Targets/Yuedu/SharedApp/GlobalSettings.swift` |
| TTS | `Modules/Core/TTS/`, `Modules/Features/Reader/TTS/`, `Modules/Features/Settings/TTSSettingsView.swift` |
| Search | `Modules/Features/Search/`, `Modules/Services/Online/SearchAggregator.swift` |
| Sync and offline download | `Modules/Services/iCloud/`, `Modules/Services/WebDAV/`, `Modules/Services/Network/`, `Modules/Services/Online/OnlineReadingPipeline.swift`, `Modules/Features/Settings/DownloadManagementView.swift` |
| RSS, comics, replacement rules | `Modules/Services/RSS/`, `Modules/Features/RSS/`, `Modules/Core/Comic/`, `Modules/Features/Manga/`, `Modules/Core/Replace/`, `Modules/Features/Settings/ReplaceRuleListView.swift` |


## Entry Points

| Need | Read first |
| --- | --- |
| App launch and environment injection | `Targets/Yuedu/SharedApp/yuedu_appApp.swift`, `Targets/Yuedu/SharedApp/AppDependencies.swift` |
| Main tabs | `Targets/Yuedu/SharedApp/ContentView.swift` |
| Bookshelf | `Modules/Features/Bookshelf/HomeView.swift` |
| Book model and store | `Modules/Services/LibraryStore/Models.swift` (`ReadingBook`, `Bookmark`), `Modules/Services/LibraryStore/BookStore.swift` (`BookStore`) |
| Reader screen | `Modules/Features/Reader/ReaderView.swift`, `Modules/Features/Reader/ReaderViewFactory.swift` |
| Reader state | `Modules/Features/Reader/ReaderViewModel.swift` |
| Paged CoreText layout | `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift` |
| CoreText contributor docs | `docs/coretext/README.md` |
| Vertical infinite scrolling | `Modules/Core/ReaderCore/CoreText/CoreTextScrollEngine.swift`, `Modules/Core/ReaderCore/CoreText/CoreTextChunkSlicer.swift`, `Modules/Features/Reader/CoreTextCollectionScrollViewController.swift` |
| Single-page CoreText rendering | `Modules/Core/ReaderCore/CoreText/CoreTextPageView.swift` |
| Scroll chunk rendering | `Modules/Features/Reader/CoreTextChunkCell.swift` |
| EPUB CSS parsing | `Modules/Core/ReaderCore/CoreText/EPUBStyleResolver.swift` |
| HTML/Markdown/TXT attributed strings | `Modules/Core/ReaderCore/CoreText/*AttributedStringBuilder.swift` |
| Vertical text normalization & config | `Modules/Core/ReaderCore/CoreText/CoreTextCommon/String+VerticalNormalization.swift`, `Modules/Core/ReaderCore/CoreText/CoreTextCommon/VerticalLayoutConfig.swift` |
| Settings | `Targets/Yuedu/SharedApp/GlobalSettings.swift` (`GlobalSettings.shared`), `Modules/Features/Settings/` |
| Account row and sign-in | `Modules/Features/Settings/ProfileView.swift`, `Modules/Features/Settings/UserDetailView.swift`, `Modules/Features/Settings/LoginView.swift` |
| Online reading and download | `Modules/Services/Online/OnlineReadingPipeline.swift`, `Modules/Services/Online/ChapterFetcher.swift`, `Modules/Features/Settings/DownloadManagementView.swift` |
| RSS list and feed parsing | `Modules/Features/RSS/RSSListView.swift`, `Modules/Features/RSS/RSSFeedView.swift`, `Modules/Services/RSS/RSSFetcher.swift` |
| Design tokens | `Modules/SharedUI/DesignSystem/DesignTokens.swift` (`DSColor`, `DSFont`, `DSSpacing`, `DSLayout`) |


## Search Patterns

Use `rg` from the project root:

```bash
ROOT="/Users/zhangruilin/Desktop/Yuedu-reader"

rg -n "struct YourViewName" "$ROOT"/Modules "$ROOT"/Targets -g '*.swift'
rg -n "store\\.yourMethod|\\.yourProperty" "$ROOT"/Modules "$ROOT"/Targets -g '*.swift'
rg -n '"Button text"' "$ROOT"/Modules "$ROOT"/Targets -g '*.swift'
rg -n '"Button text"' "$ROOT"/Resources/zh-Hant.lproj/Localizable.strings
rg -n "Notification\\.Name|NotificationCenter" "$ROOT"/Modules "$ROOT"/Targets -g '*.swift'
rg -n "@Published" "$ROOT"/Modules "$ROOT"/Targets -g '*.swift'
rg -n "^protocol " "$ROOT"/Modules "$ROOT"/Targets -g '*.swift'
```


## Extension Points

| Add | Use |
| --- | --- |
| New file format | `BookParser` + `BookParserRegistry.parsers` in `Modules/Core/EPUB/BookParsing.swift` |
| New rendered content type | `ChapterContent` in `Modules/Services/LibraryStore/UniversalBookInterfaces.swift` + `Modules/Features/Reader/ReaderViewFactory.swift` |
| New chapter source | `BookContentProvider` in `Modules/Services/Online/BookContentProvider.swift` |
| New layout engine | `PagedReaderEngine`/`ScrollReaderEngine`, `PageIndexProviding`, and `PageViewControllerVending` in `Modules/Core/ReaderCore/CoreText/PageRenderingProvider.swift` |
| New attributed-string source | `AttributedStringBuilding` in `Modules/Core/ReaderCore/CoreText/AttributedStringBuilding.swift` |
| New TTS engine | `TTSPlayable` in `Modules/Core/TTS/TTSPlayable.swift` |
| New book-source fetch logic | `BookSource` + `Modules/Core/BookSource/BookSourceFetcher+*` extensions |
| New CSS property | `HTMLCSSPropertyApplier` in `Modules/Core/ReaderCore/CoreText/CSSPropertyApplier.swift` |
| New global service | Define a protocol, add it to `Targets/Yuedu/SharedApp/AppDependencies.swift`, inject via `EnvironmentValues` |
| New page transition effect | `ProgrammaticPageTransitionControlling` in `Modules/Core/ReaderCore/ProgrammaticPageTransitionPerformer.swift` |
| Format-gated reader settings | `book.resolvedPipelineKind`, `ReadingBook` capability fields, or a persisted `ReadingBook` field |

Before adding behavior, search for existing protocols and registries.
