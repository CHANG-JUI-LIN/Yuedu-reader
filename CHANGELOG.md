# Changelog

## [Unreleased]

### Added
- RSS Legado subscription source JSON import/export and rule engine
- CoreText underline bookmark with text annotation overlay
- Drag handles for text selection adjustment
- Bookmark.Kind enum (bookmark / underline)
- loginCheckJs evaluation via JSCore (no WebView dependency)

### Fixed
- ReaderView type-checker timeout (extracted to `buildBody() -> AnyView`)
- RuleEngine bracket-aware `##` split for CSS selectors with brackets
- AnalyzeUrl page rule `<key,value>` Legado-compatible semantics
- `@put:{bare:value}` fallback when JSON parsing fails
- initScript `:regex` prefix support for regex group extraction
