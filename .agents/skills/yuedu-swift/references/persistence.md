# Persistence, change detection, and write volume

The worst field problems (≈1 GB written within ~40 s of launch; 10 s background
watchdog kills) are write-path problems. Read this before touching `BookStore`,
`BookChapterStore`, `BookSourceStore`, TOC/book-info caches, or any "save" call.

## The current write path (BookStore)

- Records live in `BookStore.records`; TOCs live separately in `BookChapterStore`
  (`books_meta.chapters/<id>.json`, LRU of 8 clean entries; dirty entries are pinned until flush).
- Debounced saves run on the serial `persistQueue`: `chapterStore.flush()` (every dirty TOC)
  → encode the whole shelf (`.sortedKeys`) → compare with the file → atomic write.
- Known main-thread waits on that queue: `saveMetaImmediately`, `flushPendingMetadataSave`
  (every scene inactive/background), `markMetadataPersisted` (after every background write),
  `notePersistedReadingData`, `reloadFromDisk`, `commitTXTBookmarks`. Each makes main wait
  for whatever the queue is doing, including a flush of dozens of multi-MB TOCs.

## Rules

1. **No-op in, no-op out.** If a refresh/merge/reconcile produced the same data, don't assign
   to `records`, don't mark the TOC dirty, don't enqueue a save, don't publish. Decide with a
   semantic comparison, computed off main.

2. **Synthesized `==` is only valid if every stored property is part of the value.**
   A stored `var id = UUID()` (or a timestamp, cache handle, runtime variable bag) makes two
   equal-looking values unequal. Either exclude such fields with a hand-written `==`, carry
   them over in merges, or compare a dedicated key. Shipped example: `OnlineChapterRef` —
   parsers create fresh UUIDs, `mergeOnlineChapters` does not carry `id` over, so
   `merged != existing` is always true and every launch refresh rewrites every TOC.

3. **Write only what the path needs.** An update check should not persist raw HTML or full
   TOCPackage caches for every book. A per-chapter field must not duplicate data derivable
   from the list (e.g. next-chapter URL in every chapter's `runtimeVariables`).

4. **Main never waits for disk.** "Save now" = enqueue on `persistQueue` and, at scene exit,
   hold a `UIApplication.beginBackgroundTask` until the queue reports done. Bookkeeping such
   as `persistedFiles` is updated inside the queue's own closure, not via `sync` from main.

5. **Don't read back to compare.** Compare encoded bytes against an in-memory hash/size of
   what the queue last wrote, not the file contents.

6. **Persist throttles.** "Last auto refresh" style stamps that gate expensive work across
   launches go to `UserDefaults`, not a `static var`.

7. **Never `try?` a persisted write or decode.** Log via `AppLogger` with the file and byte
   count. Never mark persisted / delete the old copy after a failed write. A decode failure
   must not silently fall back to defaults that are later saved over the user's data
   (`GlobalSettings` decoders are the known offenders).

8. **Big deletes off main.** Rename the directory aside on main if ordering matters, delete
   on a background queue.

9. **Measure volume, not just time.** Add `bytes=` to `library.chapters.write`,
   `library.shelf.save`, and cache writes; add a `refresh.all` span with per-book
   `listChanged`/`chaptersChanged`/`gained` so one log run proves whether refresh is a no-op.

## Checklist for any change touching saves

- [ ] What triggers this write, and how many times per launch for 300 online books?
- [ ] Is the comparison semantic (no generated ids/timestamps)?
- [ ] Is anything on main waiting for it?
- [ ] Are failures logged and non-destructive?
- [ ] Is there a span with `bytes=` and `main=`?
