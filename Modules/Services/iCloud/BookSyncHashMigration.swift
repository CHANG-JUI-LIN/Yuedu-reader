import Foundation

/// Moves a book merge shadow from the hash builds before 2026-11-05 computed to the one
/// `ReadingBook.strippedForSync()` gives now, once per shadow.
///
/// That build stopped hashing each device's own state (`withDeviceLocalState`). Left alone, the
/// shadow holds hashes that still include it, so the first sync after the update would find
/// every book with a download, a new-chapter badge or a cached remote file "edited", stamp it
/// `now`, and let this device's copy — stale progress and all — win over what was read on the
/// others: the very overwrite the change removes (feedback #6).
///
/// An entry moves only when it still matches the book as it stands, hashed the old way: proof
/// nothing changed since the last sync, so the new hash describes the same state and its
/// `updatedAt` stays. An entry that does not match is a real edit not synced yet, and is left
/// for the merge to detect and stamp.
///
/// Delete, with `legacyHashedBook`, once no device can still hold a shadow written before
/// 2026-11-05 — that is, once every install has synced on a build from after it.
enum BookSyncHashMigration {
    /// The book as builds before 2026-11-05 hashed it: `strippedForSync` as it was then.
    static func legacyHashedBook(_ book: ReadingBook) -> ReadingBook {
        var copy = book.withoutTableOfContents()
        if let reference = copy.remoteSource {
            copy.remoteSource?.cachedFilename = nil
            copy.contentFilename = reference.offlineFilename ?? ""
        }
        return copy
    }

    /// `shadow` with each live entry whose hash is `oldHash` of the local book rehashed with
    /// `newHash`; its `updatedAt` and every other entry unchanged.
    static func rehashed(
        _ shadow: [String: SyncShadowEntry],
        local: [ReadingBook],
        oldHash: (ReadingBook) -> String,
        newHash: (ReadingBook) -> String
    ) -> (shadow: [String: SyncShadowEntry], moved: Int, left: Int) {
        var result = shadow
        var moved = 0
        var left = 0
        for book in local {
            let key = book.id.uuidString
            guard let entry = shadow[key], !entry.deleted else { continue }
            guard entry.hash == oldHash(book) else {
                left += 1
                continue
            }
            let hash = newHash(book)
            if hash != entry.hash {
                result[key] = SyncShadowEntry(updatedAt: entry.updatedAt, hash: hash, deleted: false)
                moved += 1
            }
        }
        return (result, moved, left)
    }

    /// Runs `rehashed` on the shadow stored under `shadowKey` unless it already ran there.
    ///
    /// - Parameter local: the books as this device holds them — not yet stripped, so the old
    ///   hash sees what the last sync saw.
    static func runOnce(
        shadowKey: String,
        local: [ReadingBook],
        oldHash: (ReadingBook) -> String,
        newHash: (ReadingBook) -> String,
        defaults: UserDefaults = .standard
    ) {
        let doneKey = "yd_book_sync_hash_device_local_v1_" + shadowKey
        guard !defaults.bool(forKey: doneKey) else { return }
        let shadow = SyncShadowStore.load(shadowKey, defaults: defaults)
        let result = rehashed(shadow, local: local, oldHash: oldHash, newHash: newHash)
        if result.moved > 0 {
            SyncShadowStore.save(shadowKey, result.shadow, defaults: defaults)
        }
        defaults.set(true, forKey: doneKey)
        AppLogger.sync(
            "⟐ book sync hash: \(shadowKey) rehashed \(result.moved) entr(ies) without device-local state, left \(result.left) edited since the last sync",
            level: .notice
        )
    }
}
