import CloudKit
import Combine
import CryptoKit
import Foundation
import os
import UIKit

/// Diagnostic log for backup/restore. Watch on device via Console.app
/// (filter subsystem `com.yuedu.app`, category `iCloudSync`).

struct ICloudSyncPayloadFile: Equatable {
    let recordName: String
    let localURL: URL
}

/// One item inside an iCloud data blob. Unlike the old plain `[T]` blob, this
/// carries per-item sync metadata (`updatedAt`, `deleted`) so two devices can
/// last-write-wins merge and propagate deletions (tombstones) instead of one
/// device's whole file overwriting the other. `value` is nil for a tombstone.
struct CloudSyncRecord<T: Codable>: Codable {
    let id: String
    let value: T?
    let updatedAt: Date
    let deleted: Bool
}

private struct CloudSyncDownload<T: Codable> {
    let records: [FirestoreSyncRecord<T>]
    let payloadHash: String?
}

private struct CloudSyncMergeResult<T> {
    let values: [T]
    let uploaded: Bool
}

enum ICloudSyncPayload {
    /// `recordName` is the sync identity and is deliberately unchanged by the move of
    /// these two files out of Documents — a device on an older build syncs the same
    /// records, it just keeps them at the legacy path locally.
    static func defaultFiles(
        bookSourcesFile: URL = StorageLocations.bookSourcesFile,
        booksMetadataFile: URL = StorageLocations.booksMetadataFile,
        libraryDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    ) -> [ICloudSyncPayloadFile] {
        [
            ICloudSyncPayloadFile(
                recordName: "book_sources",
                localURL: bookSourcesFile
            ),
            ICloudSyncPayloadFile(
                recordName: "books_meta",
                localURL: booksMetadataFile
            ),
            ICloudSyncPayloadFile(
                recordName: "replace_rules",
                localURL: libraryDirectory.appendingPathComponent("replace_rules.json")
            )
        ]
    }
}

enum ICloudSyncError: LocalizedError {
    case accountUnavailable(CKAccountStatus)
    case missingRemoteBackup
    case missingAsset(String)
    /// A sync blob in neither the merge format nor a plain array.
    case unreadableSyncData(String)

    var errorDescription: String? {
        switch self {
        case .accountUnavailable(let status):
            switch status {
            case .available:
                return nil
            case .noAccount:
                return localized("此裝置尚未登入 iCloud")
            case .restricted:
                return localized("此裝置的 iCloud 使用受限")
            case .couldNotDetermine:
                return localized("無法確認 iCloud 狀態，請稍後再試")
            case .temporarilyUnavailable:
                return localized("iCloud 暫時無法使用，請稍後再試")
            @unknown default:
                return localized("iCloud 無法使用")
            }
        case .missingRemoteBackup:
            return localized("iCloud 尚未找到可還原的備份")
        case .missingAsset(let name):
            return String(format: localized("iCloud 備份檔案不完整：%@"), name)
        case .unreadableSyncData(let name):
            return String(format: localized("iCloud 上的同步資料無法讀取：%@"), name)
        }
    }
}

struct ICloudSyncManifest {
    let deviceId: String
    let deviceName: String
    let backupDate: Date
    let appVersion: String
}

struct ICloudSyncConflict {
    let remote: ICloudSyncManifest
    let localLastSync: Date?
}

enum ICloudSignInSyncAction: Equatable {
    case backup
    case restore
    case waitForUserChoice
}

final class ICloudSyncManager: ObservableObject {
    static let shared = ICloudSyncManager()
    static let containerIdentifier = "iCloud.com.zhangruilin.yuedureader"

    @Published private(set) var isSyncing = false
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published var lastSyncDate: Date? {
        didSet {
            if let lastSyncDate {
                UserDefaults.standard.set(lastSyncDate, forKey: Self.lastSyncKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
            }
        }
    }
    @Published var statusMessage = ""
    @Published var pendingConflict: ICloudSyncConflict?

    private static let lastSyncKey = "icloud_last_sync"
    private static let deviceIdKey = "icloud_sync_device_id"
    private static let manifestRecordName = "sync_manifest"
    private static let manifestRecordType = "YueduSyncManifest"
    private static let fileRecordType = "YueduSyncFile"
    private static let bookFileRecordType = "YueduBookFile"
    private static let uploadedBookFilesKey = "icloud_uploaded_book_files"
    /// Fixed id of the one item in the bubble-selection record, so two devices merge the
    /// same item instead of appending duplicates. Also that record's name before the split.
    private static let bubbleSelectionRecordID = "comment_bubble_selection"
    private static let readerOverlayLayoutRecordID = "reader_overlay_layout"
    /// Fixed id of the one item in the header/footer layout record; also that record's name
    /// before the split. A record of its own rather than a new payload in
    /// `reader_overlay_layout`: a build that predates the bar model still syncs that one,
    /// and would fail to decode a bar layout written into it.
    private static let readerBarLayoutRecordID = "reader_bar_layout"
    private static let readerBackgroundPicturePrefix = "readerbg_"

    // MARK: Merged records
    //
    // `_v2` since 2026-10-05. Devices on builds from before then — App Store 2.0.6 and
    // TestFlight up to build 113 — keep syncing the records without it, and newer builds no
    // longer share those with them. 2.0.6 hashed each item with an encoding whose key order
    // changed on every call, so on every sync it stamped all it held `now`, and its copy won
    // every conflict; and every build before then stored a merge's shadow before applying it,
    // so an apply that did not happen sent tombstones for books that had only arrived
    // (`shadowToCommit`). Shared, the records took books added on a newer device away from
    // it, put an older device's header/footer layout over its own, and kept a book it had
    // let go of twice (reported 2026-10-04). Of the old records, only the books those
    // devices add are still brought over (`adoptBooksAddedByOlderBuilds`).
    private static let bookSourcesRecordName = "book_sources_v2"
    private static let replaceRulesRecordName = "replace_rules_v2"
    private static let bubbleStylesRecordName = "comment_bubble_styles_v2"
    private static let bubbleSelectionRecordName = "comment_bubble_selection_v2"
    /// The saved reading backgrounds, as one merged blob; their pictures are file records
    /// named `readerbg_<hash of the file name>`.
    private static let readerBackgroundsRecordName = "reader_backgrounds_v2"
    /// The reading setup, one item per 排版生效範圍 row as last set on any device.
    private static let readingSettingsRecordName = "reading_settings_v2"
    private static let readerBarLayoutRecordName = "reader_bar_layout_v2"
    private static let booksRecordName = "books_meta_v2"
    /// The shelf as builds from before the split sync it.
    private static let olderBuildsBooksRecordName = "books_meta"

    /// Every blob `sync()` merges, and every one builds before the split left in the
    /// account, by record name — `deleteRemoteData` removes each, so a new one belongs
    /// here as well. `reader_overlay_layout` is written only by builds from before the bar
    /// layout; `reader_background_choice` only by development builds of 2026-09-29, before
    /// the background joined the rest of the reading setup.
    private static let mergedRecordNames = [
        bookSourcesRecordName, replaceRulesRecordName, bubbleStylesRecordName,
        bubbleSelectionRecordName, readerBackgroundsRecordName, readingSettingsRecordName,
        readerBarLayoutRecordName, booksRecordName,
        "book_sources", "replace_rules", "comment_bubble_styles", bubbleSelectionRecordID,
        "reader_backgrounds", "reading_settings", readerBarLayoutRecordID, olderBuildsBooksRecordName,
        "reader_background_choice", readerOverlayLayoutRecordID,
    ]

    // Local merge shadows (per-id updatedAt/hash/deleted) for the auto-merge sync, new with
    // the `_v2` records: the ones before them say what was in step with the old records.
    private static let shadowBooks = "icloud_books_v2"
    private static let shadowBookSources = "icloud_bookSources_v2"
    private static let shadowReplaceRules = "icloud_replaceRules_v2"
    private static let shadowCommentBubbleStyles = "icloud_commentBubbleStyles_v2"
    private static let shadowCommentBubbleSelection = "icloud_commentBubbleSelection_v2"
    private static let shadowReaderBarLayout = "icloud_readerBarLayout_v2"
    private static let shadowReaderBackgrounds = "icloud_readerBackgrounds_v2"
    private static let shadowReadingSettings = "icloud_readingSettings_v2"
    /// What this device synced through `books_meta` before the split: every book it had
    /// there, and every one it deleted. Only read, to tell a book an older build added from
    /// one this device already knew (`adoptBooksAddedByOlderBuilds`).
    private static let shadowBooksBeforeSplit = "icloud_books"
    /// `books_meta` as last looked through for books older builds added.
    private static let olderBuildsBooksChangeTagKey = "icloud_older_builds_books_change_tag"

    /// Bound at launch so the merge sync can read/write the live bookshelf.
    /// `BookStore` is not a singleton (created in the app entry point).
    private weak var boundBookStore: BookStore?

    private enum Field {
        static let asset = "asset"
        static let appVersion = "appVersion"
        static let backupDate = "backupDate"
        static let deviceId = "deviceId"
        static let deviceName = "deviceName"
        static let filename = "filename"
        static let name = "name"
        static let updatedAt = "updatedAt"
    }

    private let container: CKContainer
    private let database: CKDatabase

    private static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: deviceIdKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    private init(container: CKContainer = CKContainer(identifier: ICloudSyncManager.containerIdentifier)) {
        self.container = container
        database = container.privateCloudDatabase
        lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
    }

    static func signInAction(
        remoteManifest: ICloudSyncManifest?,
        hasLocalData: Bool,
        currentDeviceId: String
    ) -> ICloudSignInSyncAction {
        guard let remoteManifest else { return .backup }
        guard remoteManifest.deviceId != currentDeviceId else { return .backup }
        return hasLocalData ? .waitForUserChoice : .restore
    }

    func refreshAccountStatus() async -> CKAccountStatus {
        let status = await fetchAccountStatus()
        await MainActor.run {
            accountStatus = status
        }
        return status
    }

    func syncAfterSignIn() {
        Task {
            do {
                try await performSignInSync()
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    /// Bind the live bookshelf so `sync()` can merge it. Call once at app launch.
    func bind(bookStore: BookStore) {
        boundBookStore = bookStore
    }

    // MARK: - Auto + smart-merge sync

    /// Seamless, mergeable iCloud sync. Pulls the cloud copy, merges it with this
    /// device (last-write-wins per item + tombstones, reusing `FirestoreSyncMerge`),
    /// writes the result back locally and to the cloud, then syncs the book files
    /// (EPUB/cover). Safe to call automatically (launch/background) and manually;
    /// concurrent calls are coalesced. Unlike the old backup/restore it never
    /// blindly overwrites either side, so no conflict prompt is needed.
    func sync(reason: String = "manual") async throws {
        try await ensureAccountAvailable()
        let alreadyRunning = await MainActor.run { () -> Bool in
            if isSyncing { return true }
            isSyncing = true
            statusMessage = localized("iCloud 同步中…")
            return false
        }
        if alreadyRunning { return }
        defer { Task { @MainActor in self.isSyncing = false } }
        CrashContext.setKey("icloud_syncing", true)
        CrashContext.breadcrumb("iCloud sync start: \(reason)")
        defer { CrashContext.setKey("icloud_syncing", false) }

        AppLogger.sync("sync(\(reason)): start", level: .notice)
        do {
            // 1. Book sources (singleton store).
            let (localSources, sourceMutationRevision) = await MainActor.run {
                (BookSourceStore.shared.sources, BookSourceStore.shared.mutationRevision)
            }
            var changedRemote = false

            let sourceMerge = try await mergeType(
                recordName: Self.bookSourcesRecordName,
                shadowKey: Self.shadowBookSources,
                local: localSources,
                id: { $0.id.uuidString },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { Date(timeIntervalSince1970: TimeInterval(max($0.lastUpdateTime, 0)) / 1000) },
                applyLocally: { merged in
                    // The network merge can outlive a user deletion. Only apply its result when
                    // the store still has the exact snapshot that was merged; otherwise the
                    // deletion remains local and the next sync can publish its tombstone.
                    // Timed because this is the apply that killed a device: it runs on the
                    // main actor, and until `save()` moved to a background queue it carried a
                    // ~3 MB encode and a synchronous file write with it. The span is the
                    // evidence that it stays cheap.
                    await MainActor.run {
                        SourcePerfTrace.span("sync.apply.sources", "count=\(merged.count)") {
                            BookSourceStore.shared.replaceSourcesFromSync(
                                merged,
                                expectedMutationRevision: sourceMutationRevision
                            )
                        }
                    }
                }
            )
            changedRemote = changedRemote || sourceMerge.uploaded

            // 2. Replace rules (singleton store).
            let localRules = await MainActor.run { ReplaceRuleStore.shared.rules }
            let ruleMerge = try await mergeType(
                recordName: Self.replaceRulesRecordName,
                shadowKey: Self.shadowReplaceRules,
                local: localRules,
                id: { $0.id },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { _ in Date.distantPast },
                applyLocally: { merged in
                    await MainActor.run { ReplaceRuleStore.shared.replaceRulesFromSync(merged) }
                    return true
                }
            )
            changedRemote = changedRemote || ruleMerge.uploaded

            // 3. Custom comment-bubble styles + selection (singleton settings).
            //    Styles merge per-item (last-write-wins on their stamped
            //    `updatedAt`); the selection rides as ONE always-present record
            //    whose merge clock only advances on user selection changes.
            //    "Cleared" is a value (selectedCustomStyleID nil), never an empty
            //    local array: an empty array would let mergeType's local-deletion
            //    loop tombstone the constant-id record with `now`, killing a
            //    valid newer selection picked on another device.
            let (localBubbleStyles, bubbleSelectionClock) = await MainActor.run {
                let settings = GlobalSettings.shared
                return (settings.commentBubbleCustomStyles, settings.commentBubbleSelectionSyncClock)
            }
            let bubbleStyleMerge = try await mergeType(
                recordName: Self.bubbleStylesRecordName,
                shadowKey: Self.shadowCommentBubbleStyles,
                local: localBubbleStyles,
                id: { $0.id.uuidString },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { $0.updatedAt ?? .distantPast },
                applyLocally: { merged in
                    await MainActor.run { GlobalSettings.shared.applyCommentBubbleSync(styles: merged) }
                    return true
                }
            )
            changedRemote = changedRemote || bubbleStyleMerge.uploaded
            // Snapshot the selection AFTER applying merged styles: a style
            // removed by sync may clear the local selection (invariant cleanup),
            // which must ride this same pass as the nil value.
            let localBubbleSelectionID = await MainActor.run {
                GlobalSettings.shared.commentBubbleSelectedCustomStyleID
            }
            let bubbleSelection = ReaderCommentBubbleSyncSelection(
                selectedCustomStyleID: localBubbleSelectionID,
                modifiedAt: bubbleSelectionClock
            )
            let bubbleSelectionMerge = try await mergeType(
                recordName: Self.bubbleSelectionRecordName,
                shadowKey: Self.shadowCommentBubbleSelection,
                local: [bubbleSelection],
                id: { _ in Self.bubbleSelectionRecordID },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { $0.modifiedAt ?? .distantPast },
                applyLocally: { merged in
                    let mergedSelection = merged.first?.selectedCustomStyleID
                    await MainActor.run { GlobalSettings.shared.applyCommentBubbleSync(selection: mergedSelection) }
                    return true
                }
            )
            changedRemote = changedRemote || bubbleSelectionMerge.uploaded

            // 3b. Saved reading backgrounds (singleton settings). Per background,
            //     last-write-wins on their stamped `updatedAt`, like the bubble styles;
            //     the pictures they show follow as files, under the name each background
            //     knows them by.
            let localBackgrounds = await MainActor.run { GlobalSettings.shared.readerCustomBackgrounds }
            let backgroundMerge = try await mergeType(
                recordName: Self.readerBackgroundsRecordName,
                shadowKey: Self.shadowReaderBackgrounds,
                local: localBackgrounds,
                id: { $0.id.uuidString },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { $0.updatedAt ?? .distantPast },
                applyLocally: { merged in
                    await MainActor.run { GlobalSettings.shared.applyReaderCustomBackgroundsSync(merged) }
                    return true
                }
            )
            changedRemote = changedRemote || backgroundMerge.uploaded
            let backgroundPictures = Self.readerBackgroundPicturePayloads(backgroundMerge.values)
            var uploadedPictures = 0
            for picture in backgroundPictures {
                if try await uploadBookFileIfNeeded(picture) { uploadedPictures += 1 }
            }
            changedRemote = changedRemote || uploadedPictures > 0
            if try await downloadMissingFiles(backgroundPictures) > 0 {
                // A background already worn gets its picture only now; nothing it names
                // changed, so the reader has to be told to look again.
                await MainActor.run { GlobalSettings.shared.objectWillChange.send() }
            }

            // 3c. The reading setup: one item per 排版生效範圍 row, last-write-wins on
            //     when the row was set — so a font size set here and a line height set
            //     there both survive. After 3b, so a background it names is in the list.
            //     Each item is the snapshot taken when the row was set: switching themes
            //     changes none of them, and only a new setting reads as a local edit.
            let localReadingSettings = await MainActor.run { GlobalSettings.shared.readingSettingSyncRecords }
            let readingSettingsMerge = try await mergeType(
                recordName: Self.readingSettingsRecordName,
                shadowKey: Self.shadowReadingSettings,
                local: localReadingSettings,
                id: { $0.item },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { $0.editedAt },
                applyLocally: { merged in
                    await MainActor.run { GlobalSettings.shared.applyReadingSettingsSync(merged) }
                    return true
                }
            )
            changedRemote = changedRemote || readingSettingsMerge.uploaded

            // 4. Reader header/footer layout (singleton setting). Same shape as
            //    the bubble selection above: ONE always-present record under a
            //    constant id, whose merge clock advances only on a real user
            //    edit — never when a sync applies a remote layout, which would
            //    make both devices claim to be newest on every pass.
            let (localBarLayout, barLayoutClock) = await MainActor.run {
                let settings = GlobalSettings.shared
                return (settings.readerBarLayout, settings.readerBarLayoutSyncClock)
            }
            let barLayoutMerge = try await mergeType(
                recordName: Self.readerBarLayoutRecordName,
                shadowKey: Self.shadowReaderBarLayout,
                local: [
                    ReaderBarLayoutSyncRecord(
                        layout: localBarLayout,
                        modifiedAt: barLayoutClock
                    )
                ],
                id: { _ in Self.readerBarLayoutRecordID },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { $0.modifiedAt ?? .distantPast },
                applyLocally: { merged in
                    guard let record = merged.first else { return true }
                    return await MainActor.run {
                        GlobalSettings.shared.applyReaderBarLayoutFromSync(
                            record.layout,
                            modifiedAt: record.modifiedAt
                        )
                    }
                }
            )
            changedRemote = changedRemote || barLayoutMerge.uploaded

            // 5. Bookshelf (bound store). Progress lives in each book's
            //    lastOpenedDate, so newest-wins handles reading-progress merges too.
            if let store = boundBookStore {
                // Books added on devices still on a build from before the split. Not on the
                // way to the background, where an older build's shelf — 100 MB and more with
                // its tables of contents — has no business being downloaded. The look is
                // logged and left when it fails: the shelf here still syncs.
                if reason != "background" {
                    do {
                        try await adoptBooksAddedByOlderBuilds(into: store)
                    } catch {
                        AppLogger.sync("⟐ books from older builds not looked through: \(error.localizedDescription)", level: .error)
                    }
                }
                // Without the table of contents: each device keeps its own (`BookChapterStore`),
                // and uploading it made this blob 138 MB for a 110-book shelf, sent on every
                // trip to the background.
                let (localBooks, bookMutationRevision) = await MainActor.run {
                    (store.books.map { $0.withoutTableOfContents() }, store.mutationRevision)
                }
                let bookMerge = try await mergeType(
                    recordName: Self.booksRecordName,
                    shadowKey: Self.shadowBooks,
                    local: localBooks,
                    id: { $0.id.uuidString },
                    hash: { Self.stableHash($0.strippedForSync()) },
                    fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate },
                    applyLocally: { merged in
                        // Refused while the shelf is not the one merged: a page turn or a
                        // narrated paragraph during the round trip moves it.
                        guard let snapshot = await MainActor.run(body: {
                            store.snapshotForSync(merged, expectedMutationRevision: bookMutationRevision)
                        }) else { return false }
                        let prepared = try await BookStore.encodeSyncSnapshot(snapshot)
                        return await MainActor.run {
                            SourcePerfTrace.span("sync.apply.books", "count=\(merged.count)") {
                                store.applySyncSnapshot(prepared)
                            }
                        }
                    }
                )
                changedRemote = changedRemote || bookMerge.uploaded
            }

            // 6. Binary book files (EPUB/TXT content + cover images).
            let uploadedBookFileCount = try await uploadBookFiles()
            changedRemote = changedRemote || uploadedBookFileCount > 0
            _ = try await downloadMissingBookFiles()

            // 7. Manifest + timestamp.
            let date = Date()
            if changedRemote {
                try await saveManifest(await makeManifest(date: date))
            } else {
                AppLogger.sync("sync(\(reason)): no remote changes; manifest unchanged", level: .notice)
            }
            await MainActor.run {
                lastSyncDate = date
                statusMessage = localized("iCloud 同步成功")
            }
            AppLogger.sync("sync(\(reason)): done — \(sourceMerge.values.count) sources, \(ruleMerge.values.count) rules, uploadedBookFiles=\(uploadedBookFileCount)", level: .notice)
        } catch {
            await MainActor.run { statusMessage = error.localizedDescription }
            AppLogger.sync("sync(\(reason)) failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    /// Downloads one cloud data blob, merges it with `local`, uploads the merged blob back,
    /// hands the merged values to `applyLocally` when they differ from `local`, and then
    /// persists the new shadow (`shadowToCommit`).
    ///
    /// - Parameter applyLocally: puts the merged values in the local store; false when the
    ///   store would not take them — it changed during the round trip.
    private func mergeType<T: Codable>(
        recordName: String,
        shadowKey: String,
        local: [T],
        id: @escaping (T) -> String,
        hash: @escaping (T) -> String,
        fallbackUpdatedAt: @escaping (T) -> Date,
        applyLocally: ([T]) async throws -> Bool
    ) async throws -> CloudSyncMergeResult<T> {
        let remote = try await downloadRecords(recordName, as: T.self, id: id, fallbackUpdatedAt: fallbackUpdatedAt)
        let loadedShadow = SyncShadowStore.load(shadowKey)
        let result = Self.resolveMerge(
            local: local,
            remote: remote.records,
            shadow: loadedShadow,
            id: id,
            hash: hash,
            fallbackUpdatedAt: fallbackUpdatedAt
        )
        let uploaded = try await uploadRecords(
            recordName,
            values: result.values,
            shadow: result.shadow,
            id: id,
            remotePayloadHash: remote.payloadHash
        )
        let applied = result.shouldApplyLocally ? try await applyLocally(result.values) : true
        let shadow = Self.shadowToCommit(
            previous: loadedShadow,
            merge: result,
            local: local,
            appliedLocally: applied,
            id: id,
            hash: hash
        )
        if loadedShadow != shadow {
            SyncShadowStore.save(shadowKey, shadow)
        }
        AppLogger.sync("merge \(recordName): local=\(local.count) remote=\(remote.records.count) → \(result.values.count), uploaded=\(uploaded), applyLocally=\(result.shouldApplyLocally), applied=\(applied)", level: .notice)
        if !applied {
            AppLogger.sync("⟐ merge \(recordName): changed here during the sync, not applied; what arrived is applied by the next sync", level: .notice)
        }
        return CloudSyncMergeResult(values: result.values, uploaded: uploaded)
    }

    /// The shadow a merge leaves: what this device and the cloud now agree on.
    ///
    /// All of the merge's when its values were applied here, or there was nothing to apply.
    /// When they were not, only the entries whose merged state is the state the local copy
    /// already had — this device's own additions, edits and deletions, which the upload
    /// carried — and the previous entry for everything else.
    ///
    /// The whole shadow used to be stored before the values were applied (until
    /// 2026-10-05). An apply that did not happen — the shelf changed during the round trip
    /// (a page turn, a narrated paragraph, a chapter check), the upload threw, the app was
    /// suspended — left items in the shadow that had never been on this device, and the
    /// next sync read each one as deleted here: it sent a tombstone, and the device that
    /// had added the book deleted it. A remote edit went the same way: its hash went into
    /// the shadow, the unchanged local copy no longer matched it, and the next sync stamped
    /// that stale copy `now`, so it won over the edit. Left out, a remote item is new again
    /// next time, and a remote edit or deletion is newer again, and each is applied then.
    static func shadowToCommit<T>(
        previous: [String: SyncShadowEntry],
        merge: (values: [T], shadow: [String: SyncShadowEntry], shouldApplyLocally: Bool),
        local: [T],
        appliedLocally: Bool,
        id: (T) -> String,
        hash: (T) -> String
    ) -> [String: SyncShadowEntry] {
        guard merge.shouldApplyLocally, !appliedLocally else { return merge.shadow }
        let localHashes = Dictionary(local.map { (id($0), hash($0)) }, uniquingKeysWith: { first, _ in first })
        let mergedHashes = Dictionary(merge.values.map { (id($0), hash($0)) }, uniquingKeysWith: { first, _ in first })
        var shadow = previous
        for key in Set(merge.shadow.keys).union(previous.keys) where localHashes[key] == mergedHashes[key] {
            shadow[key] = merge.shadow[key]
        }
        return shadow
    }

    // MARK: - Books from builds before the split

    /// Books added on devices still on a build from before the split, which sync
    /// `books_meta`: brought onto this shelf by the id they carry, and nothing else of that
    /// record — not its tombstones, its edits or its timestamps, which those builds get
    /// wrong (see "Merged records"). Once those devices update, the books are the same
    /// books there and here.
    ///
    /// Looked through only when the record changed since the last look: its change tag
    /// comes without the asset, which an older build's shelf, tables of contents and all,
    /// makes 100 MB and more. Read for its ids first, and in full only when it has a book
    /// this device has never known.
    ///
    /// Delete, with `olderBuildsBooksRecordName`, `shadowBooksBeforeSplit` and
    /// `olderBuildsBooksChangeTagKey`, once no build from before the split writes
    /// `books_meta`.
    private func adoptBooksAddedByOlderBuilds(into store: BookStore) async throws {
        let recordID = fileRecordID(Self.olderBuildsBooksRecordName)
        let lastLook = UserDefaults.standard.string(forKey: Self.olderBuildsBooksChangeTagKey)
        guard let changeTag = try await fetchRecordChangeTag(recordID), changeTag != lastLook else { return }
        let record = try await fetchRecord(recordID)
        guard let asset = record[Field.asset] as? CKAsset, let url = asset.fileURL else {
            throw ICloudSyncError.missingAsset(Self.olderBuildsBooksRecordName)
        }
        let data = try Data(contentsOf: url)
        let items = try JSONDecoder().decode([CloudSyncRecord<SkippedSyncValue>].self, from: data)
        let held = await MainActor.run { store.recordIDs }
        let known = Set(held.map(\.uuidString))
            .union(SyncShadowStore.load(Self.shadowBooksBeforeSplit).keys)
            .union(SyncShadowStore.load(Self.shadowBooks).keys)
        let added = Self.idsAddedByOlderBuilds(items.map { (id: $0.id, deleted: $0.deleted) }, known: known)
        var adopted = 0
        if !added.isEmpty {
            let books = try JSONDecoder().decode([CloudSyncRecord<ReadingBook>].self, from: data)
                .compactMap { $0.deleted ? nil : $0.value }
                .filter { added.contains($0.id.uuidString) }
            adopted = await MainActor.run { store.adoptBooksAddedByOlderBuilds(books) }
        }
        UserDefaults.standard.set(record.recordChangeTag ?? changeTag, forKey: Self.olderBuildsBooksChangeTagKey)
        AppLogger.sync("⟐ books from older builds: \(items.count) item(s) in \(Self.olderBuildsBooksRecordName), \(adopted) new here", level: .notice)
    }

    /// The books in `books_meta`, as builds from before the split sync it, that this device
    /// has never known: live there, with no record here and no entry in either of its merge
    /// shadows — so neither a book it holds nor one it deleted, before the split or since.
    static func idsAddedByOlderBuilds(
        _ items: [(id: String, deleted: Bool)],
        known: Set<String>
    ) -> Set<String> {
        Set(items.filter { !$0.deleted && !known.contains($0.id) }.map(\.id))
    }

    /// Decodes nothing of an item: enough to read a blob's ids without building its books.
    private struct SkippedSyncValue: Codable {
        init(from decoder: Decoder) throws {}
        func encode(to encoder: Encoder) throws {}
    }

    /// Everything `mergeType` decides between the download and the upload, apart
    /// from the network so it can be tested.
    static func resolveMerge<T>(
        local: [T],
        remote: [FirestoreSyncRecord<T>],
        shadow loadedShadow: [String: SyncShadowEntry],
        id: (T) -> String,
        hash: (T) -> String,
        fallbackUpdatedAt: (T) -> Date,
        now: Date = Date()
    ) -> (values: [T], shadow: [String: SyncShadowEntry], shouldApplyLocally: Bool) {
        let localFingerprint = collectionFingerprint(local, id: id, hash: hash)
        var shadow = loadedShadow
        var localIDs = Set<String>(minimumCapacity: local.count)
        for v in local {
            localIDs.insert(id(v))
        }
        // Local deletions: an id we synced before but no longer have locally was
        // deleted on this device → tombstone it (newer than the remote copy) so the
        // deletion propagates and the item isn't resurrected from the cloud.
        for (key, entry) in shadow where !entry.deleted && !localIDs.contains(key) {
            shadow[key] = SyncShadowEntry(updatedAt: now, hash: "", deleted: true)
        }
        // Local edits since last sync (hash changed) must advance the item's merge
        // timestamp past the last-synced one, or newest-wins would keep treating it
        // as the stale, last-synced version and let the older remote copy overwrite
        // the fresh local one.
        for value in local {
            let key = id(value)
            guard let updated = updatedShadowEntry(
                existing: shadow[key],
                currentHash: hash(value),
                fallbackUpdatedAt: fallbackUpdatedAt(value),
                now: now
            ) else { continue }
            shadow[key] = updated
        }
        let result = FirestoreSyncMerge.merge(
            local: local, remote: remote, shadow: shadow,
            id: id, hash: hash, fallbackUpdatedAt: fallbackUpdatedAt
        )
        let shouldApplyLocally = localFingerprint != collectionFingerprint(result.values, id: id, hash: hash)
        return (result.values, result.shadow, shouldApplyLocally)
    }

    /// Reads a cloud blob into sync records. Understands the current envelope
    /// format and migrates a legacy plain `[T]` backup on the fly.
    /// One cloud data blob's records — none when the record does not exist yet. A fetch that
    /// fails, a record whose asset is missing or cannot be read, and a blob in neither format
    /// all throw. Until 2026-10-05 each of them came back as an empty blob, and the sync merged
    /// "the cloud has nothing": it uploaded this device's view over the blob, and what only
    /// other devices had was gone from it until they uploaded it again.
    private func downloadRecords<T: Codable>(
        _ recordName: String, as type: T.Type,
        id: (T) -> String, fallbackUpdatedAt: (T) -> Date
    ) async throws -> CloudSyncDownload<T> {
        let record: CKRecord
        do {
            record = try await fetchRecord(fileRecordID(recordName))
        } catch let error where isRecordNotFound(error) {
            return CloudSyncDownload(records: [], payloadHash: nil)
        } catch let error as CKError where error.code == .assetFileNotFound || error.code == .assetNotAvailable {
            // The record is there; the file it carries is not.
            AppLogger.sync("⟐ \(recordName): its file cannot be fetched (CKError \(error.code.rawValue))", level: .error)
            throw ICloudSyncError.missingAsset(recordName)
        }
        guard let asset = record[Field.asset] as? CKAsset, let url = asset.fileURL else {
            throw ICloudSyncError.missingAsset(recordName)
        }
        let data = try Data(contentsOf: url)
        let blob = try Self.decodeCloudSyncBlob(data, recordName: recordName, id: id, fallbackUpdatedAt: fallbackUpdatedAt)
        return CloudSyncDownload(records: blob.records, payloadHash: blob.payloadHash)
    }

    /// The records in one downloaded blob: the merge format, or the plain array builds from
    /// before the merge sync backed up, every item of which is live. A blob in neither is
    /// unreadable sync data, not an empty blob (see `downloadRecords`).
    static func decodeCloudSyncBlob<T: Codable>(
        _ data: Data,
        recordName: String,
        id: (T) -> String,
        fallbackUpdatedAt: (T) -> Date
    ) throws -> (records: [FirestoreSyncRecord<T>], payloadHash: String?) {
        let decoder = JSONDecoder()
        let records: [CloudSyncRecord<T>]
        do {
            records = try decoder.decode([CloudSyncRecord<T>].self, from: data)
        } catch let mergeFormatError {
            do {
                let plain = try decoder.decode([T].self, from: data)
                return (plain.map {
                    FirestoreSyncRecord(id: id($0), value: $0, updatedAt: fallbackUpdatedAt($0), deleted: false)
                }, nil)
            } catch {
                AppLogger.sync(
                    "⟐ \(recordName): \(data.count) bytes in neither the merge format (\(mergeFormatError)) nor a plain array (\(error))",
                    level: .error
                )
                throw ICloudSyncError.unreadableSyncData(recordName)
            }
        }
        return (records.map {
            FirestoreSyncRecord(id: $0.id, value: $0.value, updatedAt: $0.updatedAt, deleted: $0.deleted)
        }, try Self.cloudSyncPayloadHash(records))
    }

    /// Writes the merged values + tombstones back to the cloud blob.
    private func uploadRecords<T: Codable>(
        _ recordName: String,
        values: [T],
        shadow: [String: SyncShadowEntry],
        id: (T) -> String,
        remotePayloadHash: String?
    ) async throws -> Bool {
        var valuesByID: [String: T] = .init(minimumCapacity: values.count)
        for v in values {
            valuesByID[id(v)] = v
        }
        let records: [CloudSyncRecord<T>] = shadow.map { sid, entry in
            CloudSyncRecord(
                id: sid,
                value: entry.deleted ? nil : valuesByID[sid],
                updatedAt: entry.updatedAt,
                deleted: entry.deleted
            )
        }
        let shouldUpload = try Self.shouldUploadCloudSyncRecords(records, remotePayloadHash: remotePayloadHash)
        if !shouldUpload {
            AppLogger.sync("upload \(recordName): unchanged; skipped", level: .notice)
            return false
        }
        let data = try Self.encodeCloudSyncRecords(records)
        try await uploadData(data, recordName: recordName)
        return true
    }

    /// Uploads in-memory data as the CKAsset for a file record.
    private func uploadData(_ data: Data, recordName: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yuedu-icloud-\(recordName)-\(UUID().uuidString)")
            .appendingPathExtension("json")
        try data.write(to: tempURL, options: .atomic)
        AppLogger.sync("⟐ diskwrite uploadData \(recordName): \(data.count) bytes", level: .notice)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let recordID = fileRecordID(recordName)
        let record = (try? await fetchRecord(recordID)) ?? CKRecord(
            recordType: Self.fileRecordType,
            recordID: recordID
        )
        record[Field.name] = recordName as NSString
        record[Field.updatedAt] = Date() as NSDate
        record[Field.asset] = CKAsset(fileURL: tempURL)
        try await saveRecord(record)
    }

    /// Edit detection: equal content must hash equally every time. Without
    /// `.sortedKeys` JSONEncoder writes keys in a different order on every call —
    /// the same unchanged struct encoded 200 ways in 200 tries (2026-09-23) — so
    /// every item looked edited on every sync: its shadow was stamped `now`, the
    /// local copy won over newer edits from other devices, and every merge was
    /// applied, re-rendering the reader and the shelf behind it mid-scroll
    /// (15/16.trace). Sets need a sorted encoding of their own
    /// (`BookOfflineDownloadTask.encode(to:)`); sorting keys cannot order them.
    static func stableHash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return UUID().uuidString }
        return stableHash(data)
    }

    private static func collectionFingerprint<T>(
        _ values: [T],
        id: (T) -> String,
        hash: (T) -> String
    ) -> [String] {
        values.map { "\(id($0)):\(hash($0))" }
    }

    /// Advances a single item's sync shadow from its current local state.
    /// Returns nil when nothing needs to change (new item — the merge seeds it;
    /// unchanged live item; or a tombstone whose deletion is still newer).
    /// Returns a live entry when the item was locally edited (hash changed) or
    /// re-created under a tombstoned id and its own merge clock is newer than
    /// the deletion. The bubble-selection record has a constant id, so clearing
    /// and re-picking hits the re-creation case — without the revival the
    /// tombstone timestamp would pin the record as deleted forever.
    ///
    /// A local edit is stamped `now` unless the item's own clock already runs
    /// ahead. Stamping only that clock was wrong: a book's is `lastOpenedDate`,
    /// which 換封面 / 改書名 / 改分組 never move, so the entry kept the timestamp
    /// the last sync uploaded, `merge` saw `record.updatedAt >= localEntry
    /// .updatedAt` against the identical remote stamp, and the pre-edit cloud
    /// copy overwrote the edit on the next launch. Detection time is the honest
    /// clock for "changed since the last sync".
    static func updatedShadowEntry(
        existing: SyncShadowEntry?,
        currentHash: String,
        fallbackUpdatedAt: Date,
        now: Date = Date()
    ) -> SyncShadowEntry? {
        guard let existing else { return nil }
        if existing.deleted {
            guard fallbackUpdatedAt > existing.updatedAt else { return nil }
            return SyncShadowEntry(updatedAt: fallbackUpdatedAt, hash: currentHash, deleted: false)
        }
        guard existing.hash != currentHash else { return nil }
        return SyncShadowEntry(
            updatedAt: max(fallbackUpdatedAt, now),
            hash: currentHash,
            deleted: false
        )
    }

    static func encodeCloudSyncRecords<T: Codable>(_ records: [CloudSyncRecord<T>]) throws -> Data {
        let sortedRecords = records.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.deleted != rhs.deleted { return lhs.deleted == false }
            return lhs.updatedAt < rhs.updatedAt
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(sortedRecords)
    }

    static func cloudSyncPayloadHash<T: Codable>(_ records: [CloudSyncRecord<T>]) throws -> String {
        stableHash(try encodeCloudSyncRecords(records))
    }

    static func shouldUploadCloudSyncRecords<T: Codable>(
        _ records: [CloudSyncRecord<T>],
        remotePayloadHash: String?
    ) throws -> Bool {
        try cloudSyncPayloadHash(records) != remotePayloadHash
    }

    private static func stableHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String($0, radix: 16, uppercase: false) }.map { $0.count == 1 ? "0" + $0 : $0 }.joined()
    }

    func backup() async throws {
        try await ensureAccountAvailable()
        await setSync(true, message: localized("iCloud 備份中…"))
        defer { Task { @MainActor in self.isSyncing = false } }

        let files = ICloudSyncPayload.defaultFiles()
        for file in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.localURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            AppLogger.sync("backup: \(file.recordName) localSize=\(size)", level: .notice)
            try await uploadFileIfExists(file)
        }

        let bookFiles = dynamicBookFilePayloads()
        AppLogger.sync("backup: \(bookFiles.count) book file(s) to consider (content+covers)", level: .notice)
        _ = try await uploadBookFiles()

        let date = Date()
        let manifest = await makeManifest(date: date)
        try await saveManifest(manifest)

        await MainActor.run {
            lastSyncDate = date
            statusMessage = localized("iCloud 備份成功")
        }
    }

    func restore() async throws {
        try await performRestore(skipConflictCheck: false)
    }

    /// Permanently removes everything the sync keeps in the user's private CloudKit
    /// database — every merged blob, every book file and background picture, the
    /// manifest. This device's own data stays.
    /// Used by 刪除 iCloud 上的資料 in iCloud 同步, which also turns 自動同步 off first;
    /// otherwise the next sync would upload it all again.
    ///
    /// Until 2026-09-29 nothing called this, and it missed the bubble styles, the
    /// header/footer layout and the reading backgrounds.
    func deleteRemoteData() async throws {
        try await ensureAccountAvailable()

        await setSync(true, message: localized("正在刪除 iCloud 同步資料…"))
        defer { Task { @MainActor in self.isSyncing = false } }

        // Book files and background pictures are records of their own, named after the
        // file. The cloud's own lists name every device's, not only this one's — those
        // builds from before the split keep as well.
        var remoteBooks: [ReadingBook] = []
        for recordName in [Self.booksRecordName, Self.olderBuildsBooksRecordName] {
            remoteBooks += try await valuesNamedForDeletion(in: recordName, as: ReadingBook.self) { $0.id.uuidString }
        }
        var remoteBackgrounds: [ReaderCustomBackground] = []
        for recordName in [Self.readerBackgroundsRecordName, "reader_backgrounds"] {
            remoteBackgrounds += try await valuesNamedForDeletion(in: recordName, as: ReaderCustomBackground.self) {
                $0.id.uuidString
            }
        }
        let localBackgrounds = await MainActor.run { GlobalSettings.shared.readerCustomBackgrounds }
        let files = bookFilePayloads(localBooks() + remoteBooks)
            + Self.readerBackgroundPicturePayloads(localBackgrounds + remoteBackgrounds)
        for file in files {
            try await deleteRecordIfExists(CKRecord.ID(recordName: file.recordName))
        }
        for name in Self.mergedRecordNames {
            try await deleteRecordIfExists(fileRecordID(name))
        }
        try await deleteRecordIfExists(CKRecord.ID(recordName: Self.manifestRecordName))
        // The markers say a file is already up there; left in place, a later sync would
        // never upload the files again. The merge shadows stay: the next sync uploads
        // this device's items anyway, and they hold its deletions, which must not be
        // undone by a device that never saw them.
        UserDefaults.standard.removeObject(forKey: Self.uploadedBookFilesKey)
        AppLogger.sync("deleteRemoteData: \(files.count) file(s), \(Self.mergedRecordNames.count) blob(s)", level: .notice)

        await MainActor.run {
            lastSyncDate = nil
            statusMessage = localized("已刪除 iCloud 上的同步資料")
        }
    }

    /// The items a blob names, for `deleteRemoteData` to find their files. A fetch that fails
    /// stops the delete: it is not done until every file it can name is gone. A blob that
    /// cannot be read — its asset missing, or in neither format — names nothing, and the
    /// delete goes on and removes it with the rest: unreadable sync data fails every sync, and
    /// the delete is the way out of it, which that same blob must not block. The files only
    /// it named stay in the account.
    private func valuesNamedForDeletion<T: Codable>(
        in recordName: String,
        as type: T.Type,
        id: (T) -> String
    ) async throws -> [T] {
        do {
            return try await downloadRecords(
                recordName, as: type, id: id, fallbackUpdatedAt: { _ in .distantPast }
            ).records.compactMap(\.value)
        } catch let error as ICloudSyncError {
            switch error {
            case .missingAsset(let name), .unreadableSyncData(let name):
                AppLogger.sync("⟐ deleteRemoteData: \(name) unreadable; the files only it names stay in iCloud", level: .error)
                return []
            default:
                throw error
            }
        }
    }

    func resolveConflict(keepRemote: Bool) async throws {
        await MainActor.run { pendingConflict = nil }
        if keepRemote {
            try await performRestore(skipConflictCheck: true)
        } else {
            try await backup()
        }
    }

    func statusTitle(isAppSignedIn: Bool) -> String {
        guard isAppSignedIn else { return localized("尚未開啟同步") }
        switch accountStatus {
        case .available:
            return localized("iCloud 同步已開啟")
        case .noAccount:
            return localized("請先登入 iCloud")
        case .restricted:
            return localized("iCloud 受限")
        case .couldNotDetermine:
            return localized("iCloud 狀態待確認")
        case .temporarilyUnavailable:
            return localized("iCloud 暫時無法使用")
        @unknown default:
            return localized("iCloud 狀態待確認")
        }
    }

    private func performSignInSync() async throws {
        try await ensureAccountAvailable()
        let files = ICloudSyncPayload.defaultFiles()
        let remoteManifest = try await fetchManifestIfExists()
        switch Self.signInAction(
            remoteManifest: remoteManifest,
            hasLocalData: hasLocalSyncableData(files: files),
            currentDeviceId: Self.deviceId
        ) {
        case .restore:
            try await performRestore(skipConflictCheck: true)
        case .backup:
            try await backup()
        case .waitForUserChoice:
            guard let remoteManifest else { return }
            await MainActor.run {
                pendingConflict = ICloudSyncConflict(remote: remoteManifest, localLastSync: lastSyncDate)
                statusMessage = localized("偵測到衝突，請選擇要使用哪個版本")
            }
        }
    }

    private func performRestore(skipConflictCheck: Bool) async throws {
        try await ensureAccountAvailable()
        await setSync(true, message: localized("iCloud 還原中…"))
        defer { Task { @MainActor in self.isSyncing = false } }

        guard let remoteManifest = try await fetchManifestIfExists() else {
            throw ICloudSyncError.missingRemoteBackup
        }

        if !skipConflictCheck,
           remoteManifest.deviceId != Self.deviceId,
           hasLocalSyncableData(files: ICloudSyncPayload.defaultFiles())
        {
            let localSync = await MainActor.run { lastSyncDate }
            AppLogger.sync("restore: conflict — remote device differs and local data exists; deferring to user choice (nothing downloaded yet)", level: .notice)
            await MainActor.run {
                pendingConflict = ICloudSyncConflict(remote: remoteManifest, localLastSync: localSync)
                statusMessage = localized("偵測到衝突，請選擇要使用哪個版本")
            }
            return
        }

        AppLogger.sync("restore: downloading default files (book_sources/books_meta/replace_rules)", level: .notice)
        for file in ICloudSyncPayload.defaultFiles() {
            try await downloadFileIfExists(file)
        }

        try await downloadMissingBookFiles()

        // Reload the in-memory stores from the just-restored files so the bookshelf
        // and sources update live. This also keeps Firestore (account sync) from
        // re-deleting the restored data via stale tombstones on the next launch.
        await FirestoreSyncManager.shared.adoptRestoredLocalData()

        await MainActor.run {
            lastSyncDate = Date()
            statusMessage = localized("iCloud 還原成功")
        }
    }

    private func ensureAccountAvailable() async throws {
        let status = await refreshAccountStatus()
        guard status == .available else {
            throw ICloudSyncError.accountUnavailable(status)
        }
    }

    private func fetchAccountStatus() async -> CKAccountStatus {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    private func uploadFileIfExists(_ file: ICloudSyncPayloadFile) async throws {
        guard FileManager.default.fileExists(atPath: file.localURL.path) else { return }

        let data = try Data(contentsOf: file.localURL)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yuedu-icloud-\(file.recordName)-\(UUID().uuidString)")
            .appendingPathExtension("json")
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let recordID = fileRecordID(file.recordName)
        let record = (try? await fetchRecord(recordID)) ?? CKRecord(
            recordType: Self.fileRecordType,
            recordID: recordID
        )
        record[Field.name] = file.recordName as NSString
        record[Field.filename] = file.localURL.lastPathComponent as NSString
        record[Field.updatedAt] = Date() as NSDate
        record[Field.asset] = CKAsset(fileURL: tempURL)
        try await saveRecord(record)
    }

    private func downloadFileIfExists(_ file: ICloudSyncPayloadFile) async throws {
        let record: CKRecord
        do {
            record = try await fetchRecord(fileRecordID(file.recordName))
        } catch {
            if isRecordNotFound(error) { return }
            throw error
        }

        guard let asset = record[Field.asset] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw ICloudSyncError.missingAsset(file.recordName)
        }

        let data = try Data(contentsOf: assetURL)
        try FileManager.default.createDirectory(
            at: file.localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file.localURL, options: .atomic)

        AppLogger.sync("restore: downloaded \(file.recordName) bytes=\(data.count)", level: .notice)

        if file.recordName == "book_sources" {
            if let decoded = try? JSONDecoder().decode([BookSource].self, from: data) {
                AppLogger.sync("restore: decoded \(decoded.count) book source(s)", level: .notice)
                await MainActor.run {
                    BookSourceStore.shared.sources = decoded
                }
            } else {
                AppLogger.sync("restore: book_sources downloaded but FAILED to decode [BookSource]", level: .error)
            }
        }

        if file.recordName == "books_meta" {
            UserDefaults.standard.removeObject(forKey: "yd_books_meta")
        }
    }

    // MARK: - Book content files (EPUB/TXT + covers)

    /// Local content + cover files referenced by the current books_meta.json.
    /// Online books carry no local content file, but they DO have a locally
    /// downloaded cover (`<id>_cover.jpg`); sync that too, otherwise restored
    /// online books show a blank cover and never re-download it (the cover path
    /// is non-nil, so `downloadCoverIfNeeded` is skipped on the other device).
    private func dynamicBookFilePayloads() -> [ICloudSyncPayloadFile] {
        bookFilePayloads(localBooks())
    }

    /// The shelf as stored on this device. Empty before the first book is added.
    private func localBooks() -> [ReadingBook] {
        let url = StorageLocations.booksMetadataFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([ReadingBook].self, from: Data(contentsOf: url))
        } catch {
            AppLogger.sync("books_meta unreadable; its book files are left out: \(error.localizedDescription)", level: .error)
            return []
        }
    }

    /// The content and cover file records `books` name, each once.
    private func bookFilePayloads(_ books: [ReadingBook]) -> [ICloudSyncPayloadFile] {
        var payloads: [ICloudSyncPayloadFile] = []
        var seen = Set<String>()

        // Content files and covers no longer share a directory: content stays in
        // Documents (the user's own files), covers moved to Application Support.
        // `recordName` still hashes the bare filename, so the relocation does not
        // change any record's sync identity.
        for book in books {
            for file in Self.syncableFiles(for: book) {
                guard !file.name.isEmpty, seen.insert(file.name).inserted else { continue }
                payloads.append(
                    ICloudSyncPayloadFile(
                        recordName: "bookfile_" + Self.shortHash(file.name),
                        localURL: file.url
                    )
                )
            }
        }
        return payloads
    }

    /// The files iCloud syncs for one book, by name and location: its content file
    /// and, for a converted Aozora book, the original kept beside it, both only for a
    /// syncable local book; and its cover, for every book. Another device converts its
    /// own copy from the original rather than taking this one's EPUB.
    static func syncableFiles(for book: ReadingBook) -> [(name: String, url: URL)] {
        var files: [(name: String, url: URL)] = []
        if let content = syncableContentFilename(for: book) {
            files.append((content, StorageLocations.bookFile(content)))
            if let original = book.aozora?.originalFilename {
                files.append((original, StorageLocations.bookFile(original)))
            }
        }
        if let cover = book.coverImagePath {
            files.append((cover, StorageLocations.coverFile(cover)))
        }
        return files
    }

    static func syncableContentFilename(for book: ReadingBook) -> String? {
        guard book.isInBookshelf else { return nil }
        // Automatic remote caches belong to this device and must never become
        // uploaded book files. Only the explicitly saved offline copy is durable.
        if let remote = book.remoteSource { return remote.offlineFilename }
        return (book.isOnline || book.resolvedPipelineKind == .audio) ? nil : book.contentFilename
    }

    private func uploadBookFiles() async throws -> Int {
        let payloads = dynamicBookFilePayloads()
        guard !payloads.isEmpty else { return 0 }
        await setSync(true, message: localized("正在同步書籍檔案…"))
        var uploaded = 0
        for file in payloads {
            if try await uploadBookFileIfNeeded(file) {
                uploaded += 1
            }
        }
        AppLogger.sync("⟐ bookfiles: \(payloads.count) candidate(s), re-uploaded \(uploaded)", level: .notice)
        return uploaded
    }

    private func uploadBookFileIfNeeded(_ file: ICloudSyncPayloadFile) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.localURL.path) else { return false }
        // Content files are immutable once imported, so skip anything we already
        // uploaded at the same size.
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.localURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        let marker = "\(file.recordName):\(size)"
        if uploadedBookFileMarkers.contains(marker) { return false }

        let recordID = CKRecord.ID(recordName: file.recordName)
        let record = (try? await fetchRecord(recordID)) ?? CKRecord(
            recordType: Self.bookFileRecordType,
            recordID: recordID
        )
        record[Field.filename] = file.localURL.lastPathComponent as NSString
        record[Field.updatedAt] = Date() as NSDate
        record[Field.asset] = CKAsset(fileURL: file.localURL)
        AppLogger.sync("⟐ diskwrite bookfile UPLOAD \(file.localURL.lastPathComponent): \(size) bytes (marker miss)", level: .notice)
        try await saveRecord(record)
        rememberUploadedBookFileMarker(marker)
        return true
    }

    private func downloadMissingBookFiles() async throws {
        let fetched = try await downloadMissingFiles(dynamicBookFilePayloads())
        AppLogger.sync("restore: fetched \(fetched) book file(s)", level: .notice)
    }

    /// The pictures the saved reading backgrounds show — synced like the book files, and
    /// named after the file, so a device writes each under the name its background uses.
    static func readerBackgroundPicturePayloads(
        _ backgrounds: [ReaderCustomBackground]
    ) -> [ICloudSyncPayloadFile] {
        var seen = Set<String>()
        var payloads: [ICloudSyncPayloadFile] = []
        for background in backgrounds {
            guard let fileName = background.imageFileName, !fileName.isEmpty,
                  seen.insert(fileName).inserted else { continue }
            do {
                payloads.append(ICloudSyncPayloadFile(
                    recordName: readerBackgroundPicturePrefix + shortHash(fileName),
                    localURL: try ReaderCustomBackgroundStorageManager.shared.fileURL(fileName: fileName)
                ))
            } catch {
                AppLogger.sync("reader background folder unavailable: \(error.localizedDescription)", level: .error)
            }
        }
        return payloads
    }

    /// Fetches each of `files` this device does not have. Returns how many arrived.
    private func downloadMissingFiles(_ files: [ICloudSyncPayloadFile]) async throws -> Int {
        let missing = files.filter { !FileManager.default.fileExists(atPath: $0.localURL.path) }
        guard !missing.isEmpty else { return 0 }
        AppLogger.sync("restore: \(missing.count) file(s) missing locally; fetching", level: .notice)
        var fetched = 0
        for file in missing {
            do {
                let record = try await fetchRecord(CKRecord.ID(recordName: file.recordName))
                guard let asset = record[Field.asset] as? CKAsset, let assetURL = asset.fileURL else { continue }
                let data = try Data(contentsOf: assetURL)
                try FileManager.default.createDirectory(
                    at: file.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: file.localURL, options: .atomic)
                // A restored cover replaces a file the shelf may have found missing.
                CoverImagePipeline.shared.invalidateBookCover(at: file.localURL)
                rememberUploadedBookFileMarker("\(file.recordName):\(data.count)")
                fetched += 1
            } catch {
                if isRecordNotFound(error) { continue }
                throw error
            }
        }
        return fetched
    }

    private var uploadedBookFileMarkers: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.uploadedBookFilesKey) ?? [])
    }

    private func rememberUploadedBookFileMarker(_ marker: String) {
        var markers = uploadedBookFileMarkers
        markers.insert(marker)
        UserDefaults.standard.set(Array(markers), forKey: Self.uploadedBookFilesKey)
    }

    private static func shortHash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String($0, radix: 16, uppercase: false) }.map { $0.count == 1 ? "0" + $0 : $0 }.joined()
    }

    private func saveManifest(_ manifest: ICloudSyncManifest) async throws {
        let recordID = CKRecord.ID(recordName: Self.manifestRecordName)
        let record = (try? await fetchRecord(recordID)) ?? CKRecord(
            recordType: Self.manifestRecordType,
            recordID: recordID
        )
        record[Field.deviceId] = manifest.deviceId as NSString
        record[Field.deviceName] = manifest.deviceName as NSString
        record[Field.backupDate] = manifest.backupDate as NSDate
        record[Field.appVersion] = manifest.appVersion as NSString
        try await saveRecord(record)
    }

    private func fetchManifestIfExists() async throws -> ICloudSyncManifest? {
        do {
            let record = try await fetchRecord(CKRecord.ID(recordName: Self.manifestRecordName))
            return manifest(from: record)
        } catch {
            if isRecordNotFound(error) { return nil }
            throw error
        }
    }

    private func manifest(from record: CKRecord) -> ICloudSyncManifest? {
        guard let deviceId = record[Field.deviceId] as? String,
              let deviceName = record[Field.deviceName] as? String,
              let backupDate = record[Field.backupDate] as? Date
        else {
            return nil
        }
        let appVersion = record[Field.appVersion] as? String ?? ""
        return ICloudSyncManifest(
            deviceId: deviceId,
            deviceName: deviceName,
            backupDate: backupDate,
            appVersion: appVersion
        )
    }

    private func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let record {
                    continuation.resume(returning: record)
                } else {
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
        }
    }

    /// A record's change tag, without its fields: an empty `desiredKeys` leaves every field
    /// behind, the asset with it, so a blob of any size costs one small round trip. Nil when
    /// there is no such record.
    private func fetchRecordChangeTag(_ recordID: CKRecord.ID) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [recordID])
            operation.desiredKeys = []
            // Both blocks run on the operation's own serial queue: the record's result
            // first, when it has one, then the operation's.
            var outcome: Result<String?, Error>?
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record):
                    outcome = .success(record.recordChangeTag)
                case .failure(let error):
                    outcome = self.isRecordNotFound(error) ? .success(nil) : .failure(error)
                }
            }
            operation.fetchRecordsResultBlock = { result in
                if let outcome {
                    continuation.resume(with: outcome)
                } else if case .failure(let error) = result {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            database.add(operation)
        }
    }

    private func deleteRecordIfExists(_ recordID: CKRecord.ID) async throws {
        do {
            try await deleteRecord(recordID)
        } catch {
            if isRecordNotFound(error) { return }
            throw error
        }
    }

    private func deleteRecord(_ recordID: CKRecord.ID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.delete(withRecordID: recordID) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func saveRecord(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.save(record) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func fileRecordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "sync_file_\(name)")
    }

    private func isRecordNotFound(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem || ckError.code == .zoneNotFound
    }

    private func hasLocalSyncableData(files: [ICloudSyncPayloadFile]) -> Bool {
        files.contains { file in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.localURL.path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.intValue > 2
        }
    }

    private func makeManifest(date: Date) async -> ICloudSyncManifest {
        let deviceName = await MainActor.run { UIDevice.current.name }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return ICloudSyncManifest(
            deviceId: Self.deviceId,
            deviceName: deviceName,
            backupDate: date,
            appVersion: appVersion
        )
    }

    @MainActor
    private func setSync(_ syncing: Bool, message: String) {
        isSyncing = syncing
        statusMessage = message
    }
}
