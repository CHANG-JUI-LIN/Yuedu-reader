# Immediate TXT Import Design

## Goal

Make a selected TXT file appear on the bookshelf without waiting for full-text or chapter parsing, while still deriving useful title and author metadata from a bounded prefix of the file.

The change must preserve the existing local TXT reader pipeline: the imported file remains the source of truth, chapter indexes are built lazily from the memory-mapped file when the book is opened, and cached indexes are reused on later opens.

## Current Problem

`FileImportTab.importTXT` calls `BookParserRegistry.parse`, whose `TXTBookParser` reads the entire file, parses every chapter, rebuilds the content as one `String`, and displays a preview. The user must then press a second “Add to Bookshelf” button, which stores the rebuilt text through `importWeb`.

This bypasses `BookStore.importTxt`, even though that path already persists a local TXT file and the reader later creates byte-range chapter indexes through `TXTFileReader`, `TXTChapterParser`, and `TXTLazyAttributedStringBuilder`.

Legado MD3 and the Luoyacheng fork use the desired separation: local import creates the book record from inexpensive file metadata, while TXT encoding, table-of-contents scanning, byte offsets, and chapter content are resolved by the local-book reader pipeline.

## User Experience

After the document picker returns a TXT file:

1. Yuedu reads only a bounded prefix to infer metadata.
2. Yuedu imports the original file through the local TXT store path.
3. The add-book sheet closes after the book is persisted.
4. The new book appears at the front of the bookshelf.

There is no full-text preview and no second confirmation button for TXT files. EPUB, Markdown, JSON, manga, archive, and audiobook behavior remains unchanged.

## Metadata Probe

Introduce one TXT-specific metadata probe in the TXT domain layer. It must:

- read no more than 128 KiB from the selected file;
- decode the prefix using the same encoding-detection rules as `TXTFileReader`;
- inspect no more than the first 3,000 decoded characters;
- recognize explicit labels such as `書名`, `书名`, `作品名`, `作者`, `著者`, `Author`, and `Written by`;
- recognize a short standalone `名字 著` author line;
- trim surrounding whitespace and punctuation;
- reject empty and implausibly long captures;
- fall back to the filename without its extension for the title;
- return no inferred author when no author is found, allowing `BookStore` to use the existing canonical unknown-author value.

The probe does not identify chapters, count words, build a preview, paginate text, or load the whole file. Metadata inference failure is non-fatal because the filename and unknown-author fallbacks are valid book metadata.

The existing author patterns currently private to `TXTBookParser` should move into the shared probe so full parsing and bounded probing cannot develop separate rules.

## Data Flow

`FileImportTab` remains responsible only for presenting the document picker and invoking one store-level import use case.

The store-level TXT import performs these steps off the main actor where appropriate:

1. Hold the security-scoped file access for the complete probe-and-copy operation.
2. Probe the bounded prefix for title and author.
3. Copy or stream-transcode the file through the existing `importLocalTextFile` path.
4. Insert one `ReadingBook` with `contentPipelineKind == .txt` and persist metadata.
5. Return the imported book to the view, which closes the sheet.

No placeholder `ReadingBook` is inserted before the destination file is safely available. This avoids a bookshelf entry that points at a missing or partially written file. “Immediate” means eliminating full parsing and the second confirmation step; copying a user-selected file remains part of the import transaction.

When the book is first opened, the existing reader flow remains authoritative:

`TXTFileReader.readMappedTextFile` → cached index lookup → `TXTChapterParser.parseMappedChapterIndexes` on cache miss → `TXTLazyAttributedStringBuilder`.

## Concurrency And Cancellation

- Prefix probing and file copying must not run on the main actor.
- The current import session ID continues to suppress stale UI results.
- Cancelling or dismissing the active import must not insert a book after cancellation.
- Security-scoped access ends exactly once after probe and copy finish or fail.
- The view must not coordinate parsing, copying, persistence, and cleanup as separate steps; it calls the store use case and handles only success, cancellation, or a surfaced error.

## Error Handling

- Unsupported encoding or an unreadable source produces the existing localized import error and no bookshelf record.
- Copy or transcode failure removes any partial destination file and produces no bookshelf record.
- Metadata pattern mismatch is not an error; filename and unknown author are used.
- Errors must be logged through the existing application logging facilities rather than discarded with `try?` in the primary import path.
- No retry, delay, alternate parser, or fallback cache is introduced.

## Performance Contract

The selection-to-import path must satisfy both structural and observable requirements:

- it never calls full `BookParserRegistry.parse` for a `.txt` file;
- metadata reads are capped at 128 KiB regardless of book size;
- chapter parsing is absent from the import path;
- import tracing reports metadata-probe and file-persistence durations separately;
- UTF-8 import time should scale primarily with file copy cost, not chapter count or total text decoding.

This change does not claim zero latency for very large files or non-UTF-8 transcoding. Those costs require a separate measured optimization if they remain material after full parsing is removed.

## Tests

Add focused tests that verify:

- labeled Traditional Chinese, Simplified Chinese, and English metadata is detected from the prefix;
- a standalone `名字 著` author line is detected;
- missing metadata falls back to filename and unknown author;
- misleading long body lines are not accepted as metadata;
- content after the 128 KiB boundary cannot affect metadata;
- TXT importing preserves the original local-file pipeline and creates a `.txt`-backed `ReadingBook`;
- the TXT picker path no longer depends on `pendingContent` or full parser output.

Long-running `xcodebuild` commands are not run automatically. Verification consists of focused source/test inspection, and the user receives the exact single-test-class command to run locally.

## Out Of Scope

- Background placeholder imports that show a book before its file is safely copied.
- Chapter parsing during import.
- Changing Markdown, JSON, EPUB, manga, archive, or audiobook import behavior.
- New caches, storage formats, or reader engines.
- Broad performance or architecture changes learned from Legado beyond this TXT import boundary.
