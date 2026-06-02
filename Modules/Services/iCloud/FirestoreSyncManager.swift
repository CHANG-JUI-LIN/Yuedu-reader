import Combine
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Foundation

@MainActor
final class FirestoreSyncManager: ObservableObject {
    static let shared = FirestoreSyncManager()

    enum SyncState: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    @Published private(set) var state: SyncState = .idle

    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    private var cancellables = Set<AnyCancellable>()
    private var pushWorkItems: [String: Task<Void, Never>] = [:]
    private var pendingPositions: [String: CoreTextReadingPosition] = [:]
    private var bookStore: BookStore?
    private var isApplyingRemote = false
    private var isSyncing = false

    // Collections whose local shadow must be cleared when the account changes.
    private static let shadowCollections = [
        "books", "bookSources", "replaceRules", "rssSources", "rssFolders", "rssArticleStatuses"
    ]

    private init() {
        observeSharedStores()
    }

    var statusTitle: String {
        switch state {
        case .idle:
            return localized("等待同步")
        case .syncing:
            return localized("正在同步")
        case .synced:
            return localized("已同步")
        case .failed:
            return localized("同步失敗")
        }
    }

    var lastSyncDate: Date? {
        if case .synced(let date) = state { return date }
        return UserDefaults.standard.object(forKey: "yd_firestore_last_sync_at") as? Date
    }

    func bind(bookStore: BookStore) {
        guard self.bookStore !== bookStore else { return }
        self.bookStore = bookStore

        bookStore.$books
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("books") { try await self?.pushBooks() }
            }
            .store(in: &cancellables)
    }

    /// Pull remote state, then push local changes. Coalesces concurrent callers.
    func syncAfterSignIn() async {
        guard FirebaseAuthManager.shared.isAuthenticated else { return }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            state = .syncing
            try await pullAll()
            try await pushAll()
            markSynced()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Clears the local sync bookkeeping so a different account re-syncs cleanly.
    func resetLocalSyncState() {
        pushWorkItems.values.forEach { $0.cancel() }
        pushWorkItems.removeAll()
        pendingPositions.removeAll()
        SyncShadowStore.clearAll(collections: Self.shadowCollections + ["readingPositions"])
        UserDefaults.standard.removeObject(forKey: "yd_firestore_last_sync_at")
        UserDefaults.standard.removeObject(forKey: "yd_firestore_profile_hash")
        UserDefaults.standard.removeObject(forKey: "yd_firestore_profile_created_at")
        state = .idle
    }

    // MARK: - Profile

    func upsertCurrentProfile(provider: String? = nil) async throws {
        guard let user = FirebaseAuthManager.shared.currentUser else { return }
        let uid = user.uid
        let settings = GlobalSettings.shared
        let photoURL = settings.accountPhotoURL.isEmpty ? (user.photoURL?.absoluteString ?? "") : settings.accountPhotoURL
        let preferences = ReaderPreferences.current(settings: settings)
        let resolvedProvider = provider ?? settings.accountProvider

        // Skip the write entirely when nothing the profile cares about changed.
        let fingerprint = stableHash(ProfileFingerprint(
            displayName: settings.accountDisplayName,
            email: settings.accountEmail,
            provider: resolvedProvider,
            photoURL: photoURL,
            preferences: preferences
        ))
        if UserDefaults.standard.string(forKey: "yd_firestore_profile_hash") == fingerprint {
            return
        }

        let createdAt = try await resolveProfileCreatedAt(uid: uid)
        let profile = UserProfile(
            uid: uid,
            displayName: settings.accountDisplayName,
            email: settings.accountEmail,
            provider: resolvedProvider,
            photoURL: photoURL.isEmpty ? nil : photoURL,
            createdAt: createdAt,
            updatedAt: Date(),
            preferences: preferences
        )
        try userDocument(uid).setData(from: profile, merge: true)
        UserDefaults.standard.set(fingerprint, forKey: "yd_firestore_profile_hash")
    }

    private func resolveProfileCreatedAt(uid: String) async throws -> Date {
        if let cached = UserDefaults.standard.object(forKey: "yd_firestore_profile_created_at") as? Date {
            return cached
        }
        let existing = try? await userDocument(uid).getDocument().data(as: UserProfile.self)
        let createdAt = existing?.createdAt ?? Date()
        UserDefaults.standard.set(createdAt, forKey: "yd_firestore_profile_created_at")
        return createdAt
    }

    func uploadAvatar(data: Data) async throws -> URL {
        guard let uid = FirebaseAuthManager.shared.uid else {
            throw AuthFlowError.missingFirebaseUser
        }
        let ref = storage.reference(withPath: "avatars/\(uid).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(data, metadata: metadata)
        let url = try await ref.downloadURL()
        try await userDocument(uid).setData([
            "photoURL": url.absoluteString,
            "updatedAt": Timestamp(date: Date())
        ], merge: true)
        GlobalSettings.shared.accountPhotoURL = url.absoluteString
        // Force the profile fingerprint to refresh on the next upsert.
        UserDefaults.standard.removeObject(forKey: "yd_firestore_profile_hash")
        return url
    }

    // MARK: - Reading position (debounced)

    func scheduleReadingPositionPush(_ position: CoreTextReadingPosition, for bookId: String) {
        pendingPositions[bookId] = position
        schedulePush("position-\(bookId)") { [weak self] in
            guard let self, let pending = self.pendingPositions[bookId] else { return }
            self.pendingPositions[bookId] = nil
            try await self.writeReadingPosition(pending, for: bookId)
        }
    }

    private func writeReadingPosition(_ position: CoreTextReadingPosition, for bookId: String) async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        let envelope = SyncEnvelope(id: bookId, value: position, updatedAt: Date())
        try userDocument(uid).collection("readingPositions").document(bookId).setData(from: envelope, merge: true)
    }

    // MARK: - Account deletion

    func deleteRemoteData(uid: String) async throws {
        let userRef = userDocument(uid)
        for collection in Self.shadowCollections + ["readingPositions"] {
            try await deleteCollection(userRef.collection(collection))
        }
        try? await storage.reference(withPath: "avatars/\(uid).jpg").delete()
        try await userRef.delete()
    }

    // MARK: - Store observation

    private func observeSharedStores() {
        BookSourceStore.shared.$sources
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("bookSources") { try await self?.pushBookSources() }
            }
            .store(in: &cancellables)

        ReplaceRuleStore.shared.$rules
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("replaceRules") { try await self?.pushReplaceRules() }
            }
            .store(in: &cancellables)

        RSSStore.shared.$sources
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("rss") { try await self?.pushRSS() }
            }
            .store(in: &cancellables)

        RSSStore.shared.$folders
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("rss") { try await self?.pushRSS() }
            }
            .store(in: &cancellables)

        GlobalSettings.shared.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePush("profile") { try await self?.upsertCurrentProfile() }
            }
            .store(in: &cancellables)
    }

    private func schedulePush(_ key: String, operation: @escaping @MainActor () async throws -> Void) {
        guard FirebaseAuthManager.shared.isAuthenticated, !isApplyingRemote else { return }
        pushWorkItems[key]?.cancel()
        pushWorkItems[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await operation()
                self?.markSynced()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Pull

    private func pullAll() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        let userRef = userDocument(uid)

        if let profile = try? await userRef.getDocument().data(as: UserProfile.self) {
            GlobalSettings.shared.applyFirebaseProfile(profile)
            UserDefaults.standard.set(profile.createdAt, forKey: "yd_firestore_profile_created_at")
        }

        if let store = bookStore {
            let merged = try await pullCollection(
                ReadingBook.self,
                key: "books",
                collection: userRef.collection("books"),
                local: store.books,
                id: { $0.id.uuidString },
                hash: { [weak self] in self?.stableHash($0.strippedForSync()) ?? "" },
                fallbackUpdatedAt: { $0.lastOpenedDate ?? $0.addedDate }
            )
            store.replaceBooksFromSync(merged)
        }

        if let positions = try await fetchEnvelopes(CoreTextReadingPosition.self, at: userRef.collection("readingPositions")) {
            JSONFileReadingPositionStore.replacePositionsFromSync(positions)
        }

        let mergedSources = try await pullCollection(
            BookSource.self,
            key: "bookSources",
            collection: userRef.collection("bookSources"),
            local: BookSourceStore.shared.sources,
            id: { $0.id.uuidString },
            hash: { [weak self] in self?.stableHash($0) ?? "" },
            fallbackUpdatedAt: { Date(timeIntervalSince1970: TimeInterval(max($0.lastUpdateTime, 0)) / 1000) }
        )
        BookSourceStore.shared.replaceSourcesFromSync(mergedSources)

        let mergedRules = try await pullCollection(
            ReplaceRule.self,
            key: "replaceRules",
            collection: userRef.collection("replaceRules"),
            local: ReplaceRuleStore.shared.rules,
            id: { $0.id },
            hash: { [weak self] in self?.stableHash($0) ?? "" },
            fallbackUpdatedAt: { _ in .distantPast }
        )
        ReplaceRuleStore.shared.replaceRulesFromSync(mergedRules)

        let mergedRSSSources = try await pullCollection(
            RSSSource.self,
            key: "rssSources",
            collection: userRef.collection("rssSources"),
            local: RSSStore.shared.sources,
            id: { $0.id },
            hash: { [weak self] in self?.stableHash($0) ?? "" },
            fallbackUpdatedAt: { Date(timeIntervalSince1970: max($0.lastUpdateTime, 0)) }
        )
        let mergedRSSFolders = try await pullCollection(
            RSSFolder.self,
            key: "rssFolders",
            collection: userRef.collection("rssFolders"),
            local: RSSStore.shared.folders,
            id: { $0.id },
            hash: { [weak self] in self?.stableHash($0) ?? "" },
            fallbackUpdatedAt: { _ in .distantPast }
        )
        let mergedRSSStatuses = try await pullCollection(
            RSSArticleStatus.self,
            key: "rssArticleStatuses",
            collection: userRef.collection("rssArticleStatuses"),
            local: RSSStore.shared.firestoreArticleStatusesSnapshot,
            id: { $0.articleId },
            hash: { [weak self] in self?.stableHash($0) ?? "" },
            fallbackUpdatedAt: { $0.lastOpenedAt ?? .distantPast }
        )
        RSSStore.shared.replaceFromSync(
            sources: mergedRSSSources,
            folders: mergedRSSFolders,
            articleStatuses: mergedRSSStatuses
        )
    }

    /// Fetches a collection, merges with local using last-write-wins + tombstones,
    /// persists the resulting shadow, and returns the merged values.
    private func pullCollection<T: Codable>(
        _ type: T.Type,
        key: String,
        collection: CollectionReference,
        local: [T],
        id: (T) -> String,
        hash: (T) -> String,
        fallbackUpdatedAt: (T) -> Date
    ) async throws -> [T] {
        let remote = try await fetchRecords(T.self, at: collection)
        let shadow = SyncShadowStore.load(key)
        let result = FirestoreSyncMerge.merge(
            local: local,
            remote: remote,
            shadow: shadow,
            id: id,
            hash: hash,
            fallbackUpdatedAt: fallbackUpdatedAt
        )
        SyncShadowStore.save(key, result.shadow)
        return result.values
    }

    // MARK: - Push

    private func pushAll() async throws {
        try await upsertCurrentProfile()
        try await pushBooks()
        try await pushBookSources()
        try await pushReplaceRules()
        try await pushRSS()
    }

    private func pushBooks() async throws {
        guard let uid = FirebaseAuthManager.shared.uid, let bookStore else { return }
        let stripped = bookStore.books.map { $0.strippedForSync() }
        try await pushCollection(
            stripped,
            key: "books",
            collection: userDocument(uid).collection("books"),
            id: { $0.id.uuidString },
            hash: { [weak self] in self?.stableHash($0) ?? "" }
        )
    }

    private func pushBookSources() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        try await pushCollection(
            BookSourceStore.shared.sources,
            key: "bookSources",
            collection: userDocument(uid).collection("bookSources"),
            id: { $0.id.uuidString },
            hash: { [weak self] in self?.stableHash($0) ?? "" }
        )
    }

    private func pushReplaceRules() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        try await pushCollection(
            ReplaceRuleStore.shared.rules,
            key: "replaceRules",
            collection: userDocument(uid).collection("replaceRules"),
            id: { $0.id },
            hash: { [weak self] in self?.stableHash($0) ?? "" }
        )
    }

    private func pushRSS() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        let userRef = userDocument(uid)
        try await pushCollection(
            RSSStore.shared.sources,
            key: "rssSources",
            collection: userRef.collection("rssSources"),
            id: { $0.id },
            hash: { [weak self] in self?.stableHash($0) ?? "" }
        )
        try await pushCollection(
            RSSStore.shared.folders,
            key: "rssFolders",
            collection: userRef.collection("rssFolders"),
            id: { $0.id },
            hash: { [weak self] in self?.stableHash($0) ?? "" }
        )
        try await pushCollection(
            RSSStore.shared.firestoreArticleStatusesSnapshot,
            key: "rssArticleStatuses",
            collection: userRef.collection("rssArticleStatuses"),
            id: { $0.articleId },
            hash: { [weak self] in self?.stableHash($0) ?? "" }
        )
    }

    /// Upserts only items whose content changed, and writes tombstones for items
    /// deleted locally. Never hard-deletes remote docs that this device hasn't seen,
    /// so concurrent additions on another device are preserved.
    private func pushCollection<T: Encodable>(
        _ values: [T],
        key: String,
        collection: CollectionReference,
        id: (T) -> String,
        hash: (T) -> String
    ) async throws {
        var shadow = SyncShadowStore.load(key)
        let localIDs = Set(values.map(id))
        var operations: [(DocumentReference, [String: Any])] = []
        let now = Date()

        for value in values {
            let docID = id(value)
            let contentHash = hash(value)
            if let entry = shadow[docID], !entry.deleted, entry.hash == contentHash {
                continue // unchanged
            }
            var payload = try Firestore.Encoder().encode(value)
            payload["updatedAt"] = Timestamp(date: now)
            payload["deleted"] = false
            operations.append((collection.document(docID), payload))
            shadow[docID] = SyncShadowEntry(updatedAt: now, hash: contentHash, deleted: false)
        }

        for (docID, entry) in shadow where !entry.deleted && !localIDs.contains(docID) {
            operations.append((collection.document(docID), ["deleted": true, "updatedAt": Timestamp(date: now)]))
            shadow[docID] = SyncShadowEntry(updatedAt: now, hash: "", deleted: true)
        }

        try await commitInChunks(operations)
        SyncShadowStore.save(key, shadow)
    }

    private func commitInChunks(_ operations: [(DocumentReference, [String: Any])]) async throws {
        guard !operations.isEmpty else { return }
        let chunkSize = 450 // Firestore batch limit is 500
        var index = 0
        while index < operations.count {
            let slice = operations[index..<min(index + chunkSize, operations.count)]
            let batch = db.batch()
            for (ref, data) in slice {
                batch.setData(data, forDocument: ref, merge: true)
            }
            try await batch.commit()
            index += chunkSize
        }
    }

    // MARK: - Fetch helpers

    private func fetchRecords<T: Codable>(_ type: T.Type, at collection: CollectionReference) async throws -> [FirestoreSyncRecord<T>] {
        let snapshot = try await collection.getDocuments()
        return snapshot.documents.map { document in
            let deleted = (document.get("deleted") as? Bool) ?? false
            let updatedAt = (document.get("updatedAt") as? Timestamp)?.dateValue() ?? .distantPast
            let value = deleted ? nil : try? document.data(as: T.self)
            return FirestoreSyncRecord(id: document.documentID, value: value, updatedAt: updatedAt, deleted: deleted)
        }
    }

    private func fetchEnvelopes<T: Codable>(_ type: T.Type, at collection: CollectionReference) async throws -> [String: T]? {
        let snapshot = try await collection.getDocuments()
        guard !snapshot.documents.isEmpty else { return nil }
        var result: [String: T] = [:]
        for document in snapshot.documents {
            if (document.get("deleted") as? Bool) == true { continue }
            if let envelope = try? document.data(as: SyncEnvelope<T>.self) {
                result[document.documentID] = envelope.value
            } else if let value = try? document.data(as: T.self) {
                result[document.documentID] = value
            }
        }
        return result
    }

    private func deleteCollection(_ collection: CollectionReference) async throws {
        let snapshot = try await collection.getDocuments()
        guard !snapshot.documents.isEmpty else { return }
        let batch = db.batch()
        snapshot.documents.forEach { batch.deleteDocument($0.reference) }
        try await batch.commit()
    }

    private func userDocument(_ uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }

    private func markSynced() {
        let date = Date()
        UserDefaults.standard.set(date, forKey: "yd_firestore_last_sync_at")
        state = .synced(date)
    }

    /// Deterministic content hash used for change detection (stable across launches).
    private func stableHash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ProfileFingerprint: Encodable {
    var displayName: String
    var email: String
    var provider: String
    var photoURL: String
    var preferences: ReaderPreferences
}

private struct SyncEnvelope<T: Codable>: Codable {
    var id: String
    var value: T
    var updatedAt: Date
}

struct FirestoreSyncRecord<Value> {
    var id: String
    var value: Value?
    var updatedAt: Date
    var deleted: Bool
}

struct SyncShadowEntry: Codable, Equatable {
    var updatedAt: Date
    var hash: String
    var deleted: Bool
}

enum FirestoreSyncMerge {
    /// Last-write-wins merge that understands tombstones in both directions.
    /// Returns the resolved values plus an updated shadow (per-id timestamp/hash/deleted).
    static func merge<Value>(
        local: [Value],
        remote: [FirestoreSyncRecord<Value>],
        shadow: [String: SyncShadowEntry],
        id: (Value) -> String,
        hash: (Value) -> String,
        fallbackUpdatedAt: (Value) -> Date
    ) -> (values: [Value], shadow: [String: SyncShadowEntry]) {
        var orderedIDs: [String] = []
        var valuesByID: [String: Value] = [:]
        var newShadow: [String: SyncShadowEntry] = [:]

        // Carry forward tombstones we already know about (local deletions, possibly not pushed yet).
        for (sid, entry) in shadow where entry.deleted {
            newShadow[sid] = entry
        }

        // Seed with local values.
        for value in local {
            let valueID = id(value)
            orderedIDs.append(valueID)
            valuesByID[valueID] = value
            let updatedAt = shadow[valueID]?.updatedAt ?? fallbackUpdatedAt(value)
            newShadow[valueID] = SyncShadowEntry(updatedAt: updatedAt, hash: hash(value), deleted: false)
        }

        for record in remote {
            let localEntry = newShadow[record.id]

            if record.deleted {
                // Remote deletion wins unless we have a strictly newer local edit.
                if let localEntry, !localEntry.deleted, localEntry.updatedAt > record.updatedAt {
                    continue
                }
                valuesByID[record.id] = nil
                newShadow[record.id] = SyncShadowEntry(updatedAt: record.updatedAt, hash: "", deleted: true)
                continue
            }

            guard let value = record.value else { continue }

            if let localEntry {
                // We already have (or previously tombstoned) this id locally.
                if record.updatedAt >= localEntry.updatedAt {
                    if localEntry.deleted {
                        orderedIDs.append(record.id)
                    }
                    valuesByID[record.id] = value
                    newShadow[record.id] = SyncShadowEntry(updatedAt: record.updatedAt, hash: hash(value), deleted: false)
                }
            } else {
                // Brand new remote item.
                orderedIDs.append(record.id)
                valuesByID[record.id] = value
                newShadow[record.id] = SyncShadowEntry(updatedAt: record.updatedAt, hash: hash(value), deleted: false)
            }
        }

        let values = orderedIDs.compactMap { valuesByID[$0] }
        return (values, newShadow)
    }
}

enum SyncShadowStore {
    private static let prefix = "yd_firestore_shadow_"

    static func load(_ collection: String) -> [String: SyncShadowEntry] {
        guard let data = UserDefaults.standard.data(forKey: prefix + collection),
              let decoded = try? JSONDecoder().decode([String: SyncShadowEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func save(_ collection: String, _ entries: [String: SyncShadowEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: prefix + collection)
    }

    static func clearAll(collections: [String]) {
        for collection in collections {
            UserDefaults.standard.removeObject(forKey: prefix + collection)
        }
    }
}
