import CloudKit
import Combine
import CryptoKit
import Foundation
import os
import UIKit

/// Diagnostic log for backup/restore. Watch on device via Console.app
/// (filter subsystem `com.yuedu.app`, category `iCloudSync`).
private let iCloudSyncLog = Logger(subsystem: "com.yuedu.app", category: "iCloudSync")

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
    let shouldApplyLocally: Bool
    let uploaded: Bool
}

enum ICloudSyncPayload {
    static func defaultFiles(
        documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        libraryDirectory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    ) -> [ICloudSyncPayloadFile] {
        [
            ICloudSyncPayloadFile(
                recordName: "book_sources",
                localURL: documentsDirectory.appendingPathComponent("book_sources.json")
            ),
            ICloudSyncPayloadFile(
                recordName: "books_meta",
                localURL: documentsDirectory.appendingPathComponent("books_meta.json")
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

    // Local merge shadows (per-id updatedAt/hash/deleted) for the auto-merge sync.
    private static let shadowBooks = "icloud_books"
    private static let shadowBookSources = "icloud_bookSources"
    private static let shadowReplaceRules = "icloud_replaceRules"

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

        iCloudSyncLog.notice("sync(\(reason, privacy: .public)): start")
        do {
            // 1. Book sources (singleton store).
            let localSources = await MainActor.run { BookSourceStore.shared.sources }
            var changedRemote = false

            let sourceMerge = try await mergeType(
                recordName: "book_sources",
                shadowKey: Self.shadowBookSources,
                local: localSources,
                id: { $0.id.uuidString },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { Date(timeIntervalSince1970: TimeInterval(max($0.lastUpdateTime, 0)) / 1000) }
            )
            changedRemote = changedRemote || sourceMerge.uploaded
            if sourceMerge.shouldApplyLocally {
                await MainActor.run { BookSourceStore.shared.replaceSourcesFromSync(sourceMerge.values) }
            }

            // 2. Replace rules (singleton store).
            let localRules = await MainActor.run { ReplaceRuleStore.shared.rules }
            let ruleMerge = try await mergeType(
                recordName: "replace_rules",
                shadowKey: Self.shadowReplaceRules,
                local: localRules,
                id: { $0.id },
                hash: { Self.stableHash($0) },
                fallbackUpdatedAt: { _ in Date.distantPast }
            )
            changedRemote = changedRemote || ruleMerge.uploaded
            if ruleMerge.shouldApplyLocally {
                await MainActor.run { ReplaceRuleStore.shared.replaceRulesFromSync(ruleMerge.values) }
            }

            // 3. Bookshelf (bound store). Progress lives in each book's
            //    lastOpenedDate, so newest-wins handles reading-progress merges too.
            if let store = boundBookStore {
                let localBooks = await MainActor.run { store.books }
                let bookMerge = try await mergeType(
                    recordName: "books_meta",
                    shadowKey: Self.shadowBooks,
                    local: localBooks,
                    id: { $0.id.uuidString },
                    hash: { Self.stableHash($0.strippedForSync()) },
                    fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate }
                )
                changedRemote = changedRemote || bookMerge.uploaded
                if bookMerge.shouldApplyLocally {
                    await MainActor.run { store.replaceBooksFromSync(bookMerge.values) }
                }
            }

            // 4. Binary book files (EPUB/TXT content + cover images).
            let uploadedBookFileCount = try await uploadBookFiles()
            changedRemote = changedRemote || uploadedBookFileCount > 0
            _ = try await downloadMissingBookFiles()

            // 5. Manifest + timestamp.
            let date = Date()
            if changedRemote {
                try await saveManifest(await makeManifest(date: date))
            } else {
                iCloudSyncLog.notice("sync(\(reason, privacy: .public)): no remote changes; manifest unchanged")
            }
            await MainActor.run {
                lastSyncDate = date
                statusMessage = localized("iCloud 同步成功")
            }
            iCloudSyncLog.notice("sync(\(reason, privacy: .public)): done — \(sourceMerge.values.count) sources, \(ruleMerge.values.count) rules, uploadedBookFiles=\(uploadedBookFileCount)")
        } catch {
            await MainActor.run { statusMessage = error.localizedDescription }
            iCloudSyncLog.error("sync(\(reason, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Downloads one cloud data blob, merges it with `local`, persists the new
    /// shadow, uploads the merged blob back, and returns the merged values.
    private func mergeType<T: Codable>(
        recordName: String,
        shadowKey: String,
        local: [T],
        id: @escaping (T) -> String,
        hash: @escaping (T) -> String,
        fallbackUpdatedAt: @escaping (T) -> Date
    ) async throws -> CloudSyncMergeResult<T> {
        let localFingerprint = Self.collectionFingerprint(local, id: id, hash: hash)
        let remote = try await downloadRecords(recordName, as: T.self, id: id, fallbackUpdatedAt: fallbackUpdatedAt)
        var shadow = SyncShadowStore.load(shadowKey)
        let loadedShadow = shadow
        let localIDs = Set(local.map(id))
        let now = Date()
        // Local deletions: an id we synced before but no longer have locally was
        // deleted on this device → tombstone it (newer than the remote copy) so the
        // deletion propagates and the item isn't resurrected from the cloud.
        for (key, entry) in shadow where !entry.deleted && !localIDs.contains(key) {
            shadow[key] = SyncShadowEntry(updatedAt: now, hash: "", deleted: true)
        }
        // Local edits since last sync (hash changed) must advance the item's merge
        // timestamp to its own modified time (e.g. a book's lastOpenedDate), or
        // newest-wins would keep treating it as the stale, last-synced version and
        // let an older remote copy overwrite the fresh local one.
        for value in local {
            let key = id(value)
            guard let entry = shadow[key], !entry.deleted else { continue }
            let currentHash = hash(value)
            if entry.hash != currentHash {
                shadow[key] = SyncShadowEntry(
                    updatedAt: fallbackUpdatedAt(value), hash: currentHash, deleted: false
                )
            }
        }
        let result = FirestoreSyncMerge.merge(
            local: local, remote: remote.records, shadow: shadow,
            id: id, hash: hash, fallbackUpdatedAt: fallbackUpdatedAt
        )
        if loadedShadow != result.shadow {
            SyncShadowStore.save(shadowKey, result.shadow)
        }
        let uploaded = try await uploadRecords(
            recordName,
            values: result.values,
            shadow: result.shadow,
            id: id,
            remotePayloadHash: remote.payloadHash
        )
        let shouldApplyLocally = localFingerprint != Self.collectionFingerprint(result.values, id: id, hash: hash)
        iCloudSyncLog.notice("merge \(recordName, privacy: .public): local=\(local.count) remote=\(remote.records.count) → \(result.values.count), uploaded=\(uploaded)")
        return CloudSyncMergeResult(values: result.values, shouldApplyLocally: shouldApplyLocally, uploaded: uploaded)
    }

    /// Reads a cloud blob into sync records. Understands the current envelope
    /// format and migrates a legacy plain `[T]` backup on the fly.
    private func downloadRecords<T: Codable>(
        _ recordName: String, as type: T.Type,
        id: (T) -> String, fallbackUpdatedAt: (T) -> Date
    ) async throws -> CloudSyncDownload<T> {
        guard let record = try? await fetchRecord(fileRecordID(recordName)),
              let asset = record[Field.asset] as? CKAsset,
              let url = asset.fileURL,
              let data = try? Data(contentsOf: url) else {
            return CloudSyncDownload(records: [], payloadHash: nil)
        }

        if let records = try? JSONDecoder().decode([CloudSyncRecord<T>].self, from: data) {
            return CloudSyncDownload(records: records.map {
                FirestoreSyncRecord(id: $0.id, value: $0.value, updatedAt: $0.updatedAt, deleted: $0.deleted)
            }, payloadHash: try? Self.cloudSyncPayloadHash(records))
        }
        // Legacy plain-array backup: treat every item as a live record.
        if let plain = try? JSONDecoder().decode([T].self, from: data) {
            return CloudSyncDownload(records: plain.map {
                FirestoreSyncRecord(id: id($0), value: $0, updatedAt: fallbackUpdatedAt($0), deleted: false)
            }, payloadHash: nil)
        }
        return CloudSyncDownload(records: [], payloadHash: nil)
    }

    /// Writes the merged values + tombstones back to the cloud blob.
    private func uploadRecords<T: Codable>(
        _ recordName: String,
        values: [T],
        shadow: [String: SyncShadowEntry],
        id: (T) -> String,
        remotePayloadHash: String?
    ) async throws -> Bool {
        let valuesByID = Dictionary(values.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
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
            iCloudSyncLog.notice("upload \(recordName, privacy: .public): unchanged; skipped")
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
        iCloudSyncLog.notice("⟐ diskwrite uploadData \(recordName, privacy: .public): \(data.count) bytes")
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

    private static func stableHash<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return UUID().uuidString }
        return stableHash(data)
    }

    private static func collectionFingerprint<T>(
        _ values: [T],
        id: (T) -> String,
        hash: (T) -> String
    ) -> [String] {
        values.map { "\(id($0)):\(hash($0))" }
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
            iCloudSyncLog.notice("backup: \(file.recordName, privacy: .public) localSize=\(size)")
            try await uploadFileIfExists(file)
        }

        let bookFiles = dynamicBookFilePayloads()
        iCloudSyncLog.notice("backup: \(bookFiles.count) book file(s) to consider (content+covers)")
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

    /// Permanently removes the account's synced data (manifest + uploaded files)
    /// from the user's private CloudKit database. Used by account deletion.
    func deleteRemoteData() async throws {
        let status = await refreshAccountStatus()
        // Nothing to delete remotely when no iCloud account is signed in here.
        guard status == .available else { return }

        await setSync(true, message: localized("正在刪除 iCloud 同步資料…"))
        defer { Task { @MainActor in self.isSyncing = false } }

        for file in ICloudSyncPayload.defaultFiles() {
            try await deleteRecordIfExists(fileRecordID(file.recordName))
        }
        for file in dynamicBookFilePayloads() {
            try await deleteRecordIfExists(CKRecord.ID(recordName: file.recordName))
        }
        try await deleteRecordIfExists(CKRecord.ID(recordName: Self.manifestRecordName))
        UserDefaults.standard.removeObject(forKey: Self.uploadedBookFilesKey)

        await MainActor.run {
            lastSyncDate = nil
            statusMessage = localized("已刪除 iCloud 上的同步資料")
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
            iCloudSyncLog.notice("restore: conflict — remote device differs and local data exists; deferring to user choice (nothing downloaded yet)")
            await MainActor.run {
                pendingConflict = ICloudSyncConflict(remote: remoteManifest, localLastSync: localSync)
                statusMessage = localized("偵測到衝突，請選擇要使用哪個版本")
            }
            return
        }

        iCloudSyncLog.notice("restore: downloading default files (book_sources/books_meta/replace_rules)")
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

        iCloudSyncLog.notice("restore: downloaded \(file.recordName, privacy: .public) bytes=\(data.count)")

        if file.recordName == "book_sources" {
            if let decoded = try? JSONDecoder().decode([BookSource].self, from: data) {
                iCloudSyncLog.notice("restore: decoded \(decoded.count) book source(s)")
                await MainActor.run {
                    BookSourceStore.shared.sources = decoded
                }
            } else {
                iCloudSyncLog.error("restore: book_sources downloaded but FAILED to decode [BookSource]")
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
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let data = try? Data(contentsOf: docs.appendingPathComponent("books_meta.json")),
              let books = try? JSONDecoder().decode([ReadingBook].self, from: data) else {
            return []
        }
        var payloads: [ICloudSyncPayloadFile] = []
        var seen = Set<String>()
        for book in books {
            // Content file only for syncable local books; cover for every book.
            let names = [Self.syncableContentFilename(for: book), book.coverImagePath]
            for name in names.compactMap({ $0 }) where !name.isEmpty {
                guard seen.insert(name).inserted else { continue }
                payloads.append(
                    ICloudSyncPayloadFile(
                        recordName: "bookfile_" + Self.shortHash(name),
                        localURL: docs.appendingPathComponent(name)
                    )
                )
            }
        }
        return payloads
    }

    static func syncableContentFilename(for book: ReadingBook) -> String? {
        (book.isOnline || book.resolvedPipelineKind == .audio) ? nil : book.contentFilename
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
        iCloudSyncLog.notice("⟐ bookfiles: \(payloads.count) candidate(s), re-uploaded \(uploaded)")
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
        iCloudSyncLog.notice("⟐ diskwrite bookfile UPLOAD \(file.localURL.lastPathComponent, privacy: .public): \(size) bytes (marker miss)")
        try await saveRecord(record)
        rememberUploadedBookFileMarker(marker)
        return true
    }

    private func downloadMissingBookFiles() async throws {
        let missing = dynamicBookFilePayloads().filter { !FileManager.default.fileExists(atPath: $0.localURL.path) }
        iCloudSyncLog.notice("restore: \(missing.count) book file(s) missing locally; fetching (content+covers)")
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
                rememberUploadedBookFileMarker("\(file.recordName):\(data.count)")
                fetched += 1
            } catch {
                if isRecordNotFound(error) { continue }
                throw error
            }
        }
        iCloudSyncLog.notice("restore: fetched \(fetched) book file(s)")
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
