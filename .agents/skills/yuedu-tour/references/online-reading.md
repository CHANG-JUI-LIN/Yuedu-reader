# Yuedu Online Reading

Paths below are relative to the repository root. Read only the section relevant to the task.

## Online Reading Pitfalls

`bookSourceId` separates two online book types:

| | Book-source book | Browser-imported book |
| --- | --- | --- |
| `bookSourceId` | non-nil `UUID` | `nil` |
| Chapter fetch | `BookSourceFetcher.fetchChapterPackage` | `fetchBrowserImportedChapter` |
| Parsing | CSS/XPath/Regex rule engine | WebView original HTML to text |
| Source | configured book source | user imports from built-in browser |

Rules:

- `fetchBrowserImportedChapter` is the primary path for browser-imported books, not a fallback.
- `ChapterFetchManager` is an `actor`; its state is serialized by Swift concurrency.
- Generation tokens are coupled to task lifecycle. Create a new `UUID` for each new task and drop stale task results when the token no longer matches.
- `ModernParserBridge.makeEngine()` intentionally creates a fresh `ModernRuleEngine` per parse to prevent state bleed during overlapping async operations.
- `isSuspiciousChapterContent` detects dirty cached chapters that merged multiple chapters, using length over 50,000 or more than three chapter-title matches.
- For browser-imported HTML and other webpage-to-reader conversion, preserve semantic HTML blocks when they already exist. Follow the NetNewsWire pattern: keep feed/extracted `contentHTML` as HTML, sanitize unsafe tags/attributes, and inject the cleaned body into the reader template. Do not split existing `<p>` elements by character count.
- Treat inline tags such as `<a>`, `<strong>`, `<em>`, `<span>`, and `<code>` as part of their parent paragraph. Never promote an inline link into its own paragraph; this causes broken text like "處理伊朗" and the linked phrase appearing on separate paragraphs.
- Only synthesize paragraphs for true plain-text fallback or HTML with no usable block structure. In that fallback, split on explicit blank lines first; heuristic sentence/length splitting is a last resort.
- Remove obvious article noise before rendering or text extraction: dangerous tags, ad/noise DOM nodes, and standalone ad labels such as `廣告`, `广告`, or `Advertisement`. Do this with precise selectors/text checks, not broad substring deletion that can destroy legitimate words.
