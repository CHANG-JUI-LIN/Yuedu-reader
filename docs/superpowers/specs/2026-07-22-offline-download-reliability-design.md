# Offline Download Reliability Design

## Goal

Make online-book downloads truthful, resumable, additive, and safe for both text and manga. A chapter is complete only when its durable offline artifacts pass validation. One failed chapter must not block the rest of the requested selection.

This design covers download state, queue ownership, durable storage, manga completeness, lifecycle recovery, source/TOC invalidation, download-management UI, migration, diagnostics, and tests. It does not introduce a second reader or export downloaded books as independent local books.

## Confirmed Product Decisions

- A failed chapter does not stop the batch. Remaining chapters continue.
- Failed chapter indices and reasons remain visible and can be retried explicitly.
- Existing valid caches are preserved and reused.
- Completed and partially completed books can accept additional ranges.
- Fixed-delay retries and unconditional automatic retries are not allowed.
- The implementation stays in the current worktree.

## Current Failure Modes

The current implementation stores a single range plus `completedChapterCount`. That representation assumes successes are contiguous and cannot express cached gaps, failed chapters, appended ranges, or image-level progress. Resume creates a smaller replacement task, losing the original target and resetting visible progress.

Additional correctness failures are:

- `.failed` chapter packages can be counted as successful downloads.
- chapter and metadata writes discard errors and still return success;
- volume separators throw into the batch failure path;
- manga image failures are discarded and partial image sets count as complete;
- manga images live outside the directory removed and measured by download management;
- source or TOC changes clear text artifacts but can retain stale manga pages;
- reading and downloading can use different `ChapterFetchManager` instances;
- interrupted downloads resume only when the download-management view opens;
- cache size is recursively enumerated from SwiftUI view evaluation on the main actor.

## Architecture

### `OfflineDownloadManager`

Introduce one actor that owns all offline-download runtime state and exposes a small use-case interface:

```swift
protocol OfflineDownloadManaging: Sendable {
    func start(book: ReadingBook, selection: OfflineChapterSelection) async
    func pause(bookId: UUID) async
    func resume(bookId: UUID) async
    func retryFailed(bookId: UUID) async
    func remove(bookId: UUID) async
    func reconcile(bookId: UUID) async
    func reconcileInterruptedDownloads() async
}
```

Views and `ReaderViewModel` call this interface only. They do not construct remaining ranges, scan files, cancel fetchers, or mutate download progress directly.

`OnlineBookCoordinator` may remain as an adapter during migration, but it delegates all download operations to the injected manager. It must not spawn an unowned download `Task` or call another singleton manager.

### Single chapter-fetch path

`AppDependencies.live` constructs one `BookSourceFetcher`, one `ChapterFetchManager`, and one `OfflineDownloadManager`. Reading, prefetching, jumping, and downloading receive adapters around those same instances.

Cancellation is scoped by operation ownership. Pausing an offline task cancels only the download operation waiting on a shared chapter result. It does not call book-wide `cancelAll(for:)`, so reading, jump, and prefetch requests are not invalidated. Shared chapter fetches remain deduplicated by `(bookId, chapterIndex)`.

### `OfflineChapterStore`

Place durable offline concerns behind one module:

```swift
protocol OfflineChapterStoring: Sendable {
    func validationState(for request: OfflineChapterRequest) async -> OfflineChapterValidation
    func persistTextPackage(_ package: ChapterPackage, for request: OfflineChapterRequest) async throws
    func persistMangaImages(_ images: [MangaChapterParser.ParsedImage], for request: OfflineChapterRequest) async throws
    func removeChapter(bookId: UUID, chapterIndex: Int) async throws
    func removeBook(bookId: UUID) async throws
    func storageSnapshot(bookId: UUID) async throws -> OfflineStorageSnapshot
}
```

The existing `ChapterCacheRepository` remains the canonical text-package format. Its write operations become throwing and verify the committed package before returning. The new store coordinates text and manga artifacts instead of creating a parallel text cache.

Manga data remains in Application Support, but receives a per-chapter manifest containing source URL, TOC title, ordered image URLs, stored filenames, sizes, and completion time. Download management and removal include both text and manga roots.

## Persistent State Model

Replace count-only task state with a versioned task:

```swift
struct BookOfflineDownloadTask: Codable, Equatable {
    var schemaVersion: Int
    var requestedIndices: Set<Int>
    var pendingIndices: Set<Int>
    var completedIndices: Set<Int>
    var failedChapters: [Int: OfflineChapterFailure]
    var isPaused: Bool
    var startedAt: Date
    var updatedAt: Date
}
```

Running indices are runtime state and are not persisted. If the process stops, any running chapter is reconstructed as pending unless reconciliation proves it complete on disk.

`BookOfflineDownloadState` becomes:

- `none`: no requested or valid offline chapters;
- `downloading`: at least one running or pending chapter and not paused;
- `paused`: pending work exists but execution is paused;
- `partial`: no active work and at least one failed or incomplete requested chapter;
- `available`: every requested non-volume chapter validates on disk.

Progress is derived from sets, not a separately incremented counter:

- target = valid non-volume `requestedIndices`;
- complete = validated `completedIndices` intersected with target;
- failed = `failedChapters.keys` intersected with target;
- pending = target minus complete minus failed, plus runtime running when displayed separately.

Book-level convenience counts may be denormalized for UI compatibility, but reconciliation and task sets are authoritative.

## Download Flow

1. Resolve a `Range`, `Indices`, or `Single` selection against the current TOC.
2. Treat volume separators as locally available presentation entries; never enqueue a fetch for them.
3. Merge new targets into the existing task instead of replacing it.
4. Reconcile each candidate with durable storage.
5. Exclude validated chapters and chapters already pending or running.
6. Queue the remainder and persist the task before starting network work.
7. Fetch one chapter through the shared `ChapterFetchManager`.
8. Require `package.state == .cached` and non-empty content.
9. Persist and verify the text package.
10. For manga, parse the ordered image list, download missing or mismatched images to temporary files, atomically replace committed files, write the manifest, and verify every expected image.
11. Move the chapter from pending/running to completed only after validation succeeds.
12. On error, record a typed failure and continue with the next chapter.
13. Derive the final book state from remaining pending and failed indices.

Adding a new range to an available or partial book merges targets and downloads only missing chapters. Removing a download clears task state plus all associated text and manga artifacts.

## Concurrency and Performance

Correctness precedes higher concurrency. Initial scheduling is deliberately bounded:

- one chapter at a time per book to preserve chapter order, Legado runtime variables, and stateful source JavaScript;
- at most two books actively downloading at once;
- at most four image requests within one manga chapter;
- one shared chapter-fetch deduplication path for reading, prefetch, and downloads.

Add `SourcePerfTrace` spans for:

- queue wait;
- chapter fetch;
- text-package commit and validation;
- manga image download;
- manga manifest commit and validation;
- state reconciliation;
- storage-size snapshot.

Concurrency limits are internal constants for the first implementation. They are raised only after on-device before/after traces demonstrate a bottleneck and source compatibility remains unchanged.

Download-management storage size is produced by an asynchronous store snapshot. SwiftUI renders stored values and loading/error states; it never enumerates directories from computed view properties.

## Error Model

`OfflineChapterFailure` records:

- chapter index and display title;
- category: invalid chapter, network, parsing, empty content, text write, image download, image validation, canceled, or unknown;
- localized-safe diagnostic message;
- timestamp.

Raw URLs, headers, credentials, and response bodies are not persisted in user-visible error state. Detailed diagnostics go through `AppLogger` and telemetry with book ID, chapter index, category, and duration.

Cancellation caused by pause is not recorded as failure. User-requested retry moves selected failed indices back to pending and clears their previous failure only when the new attempt starts. No sleep-based retry is added.

## Manga Integrity

A manga chapter is complete only when:

- the text package validates;
- parsed image count is greater than zero;
- a manifest matches the chapter source URL, TOC title, and ordered image URLs;
- every manifest file exists, is non-empty, and has the recorded size;
- no temporary file remains part of the committed set.

Existing legacy image directories without manifests are not trusted as complete. Reconciliation can reuse non-empty files whose page index and expected URL-derived extension match, but completion requires generating and validating a new manifest. This is a migration path, not a fallback network loader.

Source changes and TOC changes invalidate chapters whose source URL or normalized title no longer matches. Their text package, manga manifest, and manga images are removed together. Reader page construction uses only manifest-validated local images; it does not attach arbitrary files by page index.

## Lifecycle Recovery

An app-level coordinator invokes `reconcileInterruptedDownloads()` after `BookStore` and dependencies are ready. It does not wait for the download-management view.

Recovery performs no blind network action before reconciliation:

1. decode and migrate task state;
2. compare requested indices with the current TOC;
3. validate disk artifacts;
4. move valid chapters to completed;
5. return interrupted running chapters to pending;
6. preserve explicit pause;
7. resume tasks that were actively downloading before termination.

iOS may suspend network and JavaScript work; this design does not claim indefinite background execution. It guarantees deterministic persistence and restart recovery when the app runs again.

## UI Design

`DownloadManagementView` remains an iOS Settings-style `Form` presented as a sheet with `.inline` title mode. It receives a view model or observable snapshot from the manager instead of orchestrating work.

Each book row shows:

- validated complete count over requested count;
- waiting, downloading, and failed counts;
- current content or image phase when active;
- asynchronously computed total storage, including manga;
- textual status plus SF Symbol, never color alone.

Available actions are state-based:

- downloading: pause;
- paused: resume and remove;
- partial: retry failed, add range, and remove;
- available: add range and remove;
- failed chapter detail: chapter title, concise reason, and retry action.

The completed reader download sheet no longer traps the user in a remove-only state. It exposes Add Chapters while retaining Remove.

The screen implements empty, loading, and error states. All new strings use `localized()` and are added to zh-Hant, zh-Hans, and en. Icon-only close and confirmation actions receive localized accessibility labels. Existing design tokens and native controls are retained.

## Migration

Custom decoding accepts the legacy fields `startChapterIndex`, `endChapterIndex`, and `completedChapterCount`.

Migration steps:

1. construct the original requested range, clamped to the current TOC;
2. exclude volume separators from network targets;
3. scan and validate existing text packages;
4. inspect legacy manga directories and create manifests only for verifiably complete sets;
5. derive completed and pending indices from disk, ignoring the legacy completed count as proof;
6. preserve paused intent;
7. map old `available` to `available` only if every target validates, otherwise `partial`;
8. persist the versioned task after reconciliation.

Migration never deletes a valid artifact. Invalid or stale artifacts are removed only when their URL/title/manifest mismatch is proven.

## Testing Strategy

Tests are written before production changes and organized around public module interfaces.

### Pure state tests

- merging ranges preserves original targets and existing progress;
- failed indices do not stop later candidates;
- pause/resume preserves targets and returns runtime work to pending;
- adding chapters to available and partial tasks queues only missing targets;
- legacy count-based tasks migrate from disk truth;
- volume separators never enter the network queue.

### Store tests

- empty content cannot commit as complete;
- text directory, body, metadata, or package write failure throws;
- checksum mismatch fails validation;
- a manga chapter missing one image is incomplete;
- a complete image set and matching manifest validates;
- source mismatch invalidates text and manga artifacts together;
- remove deletes both Documents text cache and Application Support manga data;
- storage snapshot includes both roots and runs off the main actor.

### Manager tests

- a chapter failure records its index and the following chapter still runs;
- explicit retry queues only failed chapters;
- cached chapters are not fetched again;
- pause cancels the owned download operation without book-wide cancellation;
- app recovery reconciles interrupted work before resuming;
- duplicate starts merge selections and do not duplicate chapter fetches.

### UI and integration checks

- partial and available states expose Add Chapters;
- partial state exposes Retry Failed;
- progress and error state remain readable with Dynamic Type and VoiceOver labels;
- all localization files contain the new keys.

The agent does not run long `xcodebuild` commands under repository policy. It runs standalone pure-model checks where possible, Swift parsing, localization validation, and `git diff --check`, then supplies focused Xcode test commands for the user.

## Acceptance Criteria

- No failed, empty, partially written, or partially imaged chapter increments completed progress.
- A volume separator or failed chapter cannot terminate the remaining batch.
- Pause and resume preserve the original target and validated progress.
- App restart reconciles disk state without opening download management.
- Completed and partial tasks accept additional chapter selections.
- Removing or invalidating a book clears matching text and manga artifacts.
- Reading, prefetching, and downloading share one chapter-fetch manager.
- Download-management view evaluation performs no recursive filesystem enumeration.
- Error reasons and failed chapter indices are observable and retryable.
- Performance spans exist before any claim that the new concurrency is faster.

## Non-Goals

- Creating independent exported offline-book files.
- Adding unlimited or user-configurable chapter concurrency in this change.
- Guaranteeing continuous background execution while iOS suspends the app.
- Adding delay-based retries or a second cache layer.
