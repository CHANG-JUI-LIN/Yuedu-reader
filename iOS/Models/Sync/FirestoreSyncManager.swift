import Combine
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
    private var bookStore: BookStore?
    private var isApplyingRemote = false

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
            return localized("已同步至 Firestore")
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
                self?.schedulePush("books") {
                    try await self?.pushBooks()
                }
            }
            .store(in: &cancellables)
    }

    func syncAfterSignIn() async {
        guard FirebaseAuthManager.shared.isAuthenticated else { return }
        do {
            state = .syncing
            try await pullAll()
            try await pushAll()
            markSynced()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func upsertCurrentProfile(provider: String? = nil) async throws {
        guard let user = FirebaseAuthManager.shared.currentUser else { return }
        let uid = user.uid
        let document = userDocument(uid)
        let snapshot = try? await document.getDocument()
        let existing = try? snapshot?.data(as: UserProfile.self)
        let settings = GlobalSettings.shared
        let now = Date()
        let profile = UserProfile(
            uid: uid,
            displayName: settings.accountDisplayName,
            email: settings.accountEmail,
            provider: provider ?? settings.accountProvider,
            photoURL: settings.accountPhotoURL.isEmpty ? user.photoURL?.absoluteString : settings.accountPhotoURL,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            preferences: .current(settings: settings)
        )
        try document.setData(from: profile, merge: true)
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
        return url
    }

    func pushReadingPosition(_ position: CoreTextReadingPosition, for bookId: String) async {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        do {
            let envelope = SyncEnvelope(id: bookId, value: position, updatedAt: Date())
            try userDocument(uid).collection("readingPositions").document(bookId).setData(from: envelope, merge: true)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func deleteRemoteData(uid: String) async throws {
        let userRef = userDocument(uid)
        for collection in ["books", "readingPositions", "bookSources", "replaceRules", "rssSources", "rssFolders", "rssArticleStatuses"] {
            try await deleteCollection(userRef.collection(collection))
        }
        try? await storage.reference(withPath: "avatars/\(uid).jpg").delete()
        try await userRef.delete()
    }

    private func observeSharedStores() {
        BookSourceStore.shared.$sources
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("bookSources") {
                    try await self?.pushBookSources()
                }
            }
            .store(in: &cancellables)

        ReplaceRuleStore.shared.$rules
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("replaceRules") {
                    try await self?.pushReplaceRules()
                }
            }
            .store(in: &cancellables)

        RSSStore.shared.$sources
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("rss") {
                    try await self?.pushRSS()
                }
            }
            .store(in: &cancellables)

        RSSStore.shared.$folders
            .dropFirst()
            .sink { [weak self] _ in
                self?.schedulePush("rss") {
                    try await self?.pushRSS()
                }
            }
            .store(in: &cancellables)

        GlobalSettings.shared.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePush("profile") {
                    try await self?.upsertCurrentProfile()
                }
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

    private func pullAll() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        let userRef = userDocument(uid)
        if let profile = try? await userRef.getDocument().data(as: UserProfile.self) {
            GlobalSettings.shared.applyFirebaseProfile(profile)
        }

        if let records = try await fetchRecords(ReadingBook.self, at: userRef.collection("books")) {
            let local = bookStore?.books ?? []
            let merged = FirestoreSyncMerge.merge(
                local: local,
                remote: records,
                id: { $0.id.uuidString },
                localUpdatedAt: { SyncTimestampStore.updatedAt(collection: "books", id: $0.id.uuidString) ?? ($0.lastOpenedDate ?? $0.addedDate) }
            )
            bookStore?.replaceBooksFromSync(merged.values)
            SyncTimestampStore.update(collection: "books", timestamps: merged.timestamps)
        }

        if let positions = try await fetchEnvelopes(CoreTextReadingPosition.self, at: userRef.collection("readingPositions")) {
            JSONFileReadingPositionStore.replacePositionsFromSync(positions)
        }

        if let records = try await fetchRecords(BookSource.self, at: userRef.collection("bookSources")) {
            let merged = FirestoreSyncMerge.merge(
                local: BookSourceStore.shared.sources,
                remote: records,
                id: { $0.id.uuidString },
                localUpdatedAt: { source in
                    SyncTimestampStore.updatedAt(collection: "bookSources", id: source.id.uuidString)
                        ?? Date(timeIntervalSince1970: TimeInterval(max(source.lastUpdateTime, 0)) / 1000)
                }
            )
            BookSourceStore.shared.replaceSourcesFromSync(merged.values)
            SyncTimestampStore.update(collection: "bookSources", timestamps: merged.timestamps)
        }

        if let records = try await fetchRecords(ReplaceRule.self, at: userRef.collection("replaceRules")) {
            let merged = FirestoreSyncMerge.merge(
                local: ReplaceRuleStore.shared.rules,
                remote: records,
                id: { $0.id },
                localUpdatedAt: { SyncTimestampStore.updatedAt(collection: "replaceRules", id: $0.id) }
            )
            ReplaceRuleStore.shared.replaceRulesFromSync(merged.values)
            SyncTimestampStore.update(collection: "replaceRules", timestamps: merged.timestamps)
        }

        let rssSourceRecords = try await fetchRecords(RSSSource.self, at: userRef.collection("rssSources"))
        let rssFolderRecords = try await fetchRecords(RSSFolder.self, at: userRef.collection("rssFolders"))
        let rssStatusRecords = try await fetchRecords(RSSArticleStatus.self, at: userRef.collection("rssArticleStatuses"))
        if rssSourceRecords != nil || rssFolderRecords != nil || rssStatusRecords != nil {
            let sourceMerge = rssSourceRecords.map { records in
                FirestoreSyncMerge.merge(
                    local: RSSStore.shared.sources,
                    remote: records,
                    id: { $0.id },
                    localUpdatedAt: { source in
                        SyncTimestampStore.updatedAt(collection: "rssSources", id: source.id)
                            ?? Date(timeIntervalSince1970: max(source.lastUpdateTime, 0))
                    }
                )
            }
            let folderMerge = rssFolderRecords.map { records in
                FirestoreSyncMerge.merge(
                    local: RSSStore.shared.folders,
                    remote: records,
                    id: { $0.id },
                    localUpdatedAt: { SyncTimestampStore.updatedAt(collection: "rssFolders", id: $0.id) }
                )
            }
            let statusMerge = rssStatusRecords.map { records in
                FirestoreSyncMerge.merge(
                    local: RSSStore.shared.firestoreArticleStatusesSnapshot,
                    remote: records,
                    id: { $0.articleId },
                    localUpdatedAt: { status in
                        SyncTimestampStore.updatedAt(collection: "rssArticleStatuses", id: status.articleId)
                            ?? status.lastOpenedAt
                    }
                )
            }
            RSSStore.shared.replaceFromSync(
                sources: sourceMerge?.values,
                folders: folderMerge?.values,
                articleStatuses: statusMerge?.values
            )
            if let sourceMerge {
                SyncTimestampStore.update(collection: "rssSources", timestamps: sourceMerge.timestamps)
            }
            if let folderMerge {
                SyncTimestampStore.update(collection: "rssFolders", timestamps: folderMerge.timestamps)
            }
            if let statusMerge {
                SyncTimestampStore.update(collection: "rssArticleStatuses", timestamps: statusMerge.timestamps)
            }
        }
    }

    private func pushAll() async throws {
        try await upsertCurrentProfile()
        try await pushBooks()
        try await pushBookSources()
        try await pushReplaceRules()
        try await pushRSS()
    }

    private func pushBooks() async throws {
        guard let uid = FirebaseAuthManager.shared.uid, let bookStore else { return }
        try await writeCollection(bookStore.books, to: userDocument(uid).collection("books"), collectionKey: "books") { $0.id.uuidString }
    }

    private func pushBookSources() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        try await writeCollection(BookSourceStore.shared.sources, to: userDocument(uid).collection("bookSources"), collectionKey: "bookSources") { $0.id.uuidString }
    }

    private func pushReplaceRules() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        try await writeCollection(ReplaceRuleStore.shared.rules, to: userDocument(uid).collection("replaceRules"), collectionKey: "replaceRules") { $0.id }
    }

    private func pushRSS() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        let userRef = userDocument(uid)
        try await writeCollection(RSSStore.shared.sources, to: userRef.collection("rssSources"), collectionKey: "rssSources") { $0.id }
        try await writeCollection(RSSStore.shared.folders, to: userRef.collection("rssFolders"), collectionKey: "rssFolders") { $0.id }
        try await writeCollection(RSSStore.shared.firestoreArticleStatusesSnapshot, to: userRef.collection("rssArticleStatuses"), collectionKey: "rssArticleStatuses") { $0.articleId }
    }

    private func writeCollection<T: Codable>(
        _ values: [T],
        to collection: CollectionReference,
        collectionKey: String,
        id: (T) -> String
    ) async throws {
        let localIDs = Set(values.map(id))
        let snapshot = try await collection.getDocuments()
        for document in snapshot.documents where !localIDs.contains(document.documentID) {
            try await document.reference.delete()
        }

        let now = Date()
        var timestamps: [String: Date] = [:]
        for value in values {
            try collection.document(id(value)).setData(from: value, merge: true)
            try await collection.document(id(value)).setData(["updatedAt": Timestamp(date: now)], merge: true)
            timestamps[id(value)] = now
        }
        SyncTimestampStore.update(collection: collectionKey, timestamps: timestamps)
    }

    private func fetchCollection<T: Codable>(_ type: T.Type, at collection: CollectionReference) async throws -> [T]? {
        let snapshot = try await collection.getDocuments()
        guard !snapshot.documents.isEmpty else { return nil }
        return snapshot.documents.compactMap { try? $0.data(as: T.self) }
    }

    private func fetchRecords<T: Codable>(_ type: T.Type, at collection: CollectionReference) async throws -> [FirestoreSyncRecord<T>]? {
        let snapshot = try await collection.getDocuments()
        guard !snapshot.documents.isEmpty else { return nil }
        return snapshot.documents.compactMap { document in
            guard let value = try? document.data(as: T.self) else { return nil }
            let updatedAt = (document.get("updatedAt") as? Timestamp)?.dateValue() ?? .distantPast
            return FirestoreSyncRecord(id: document.documentID, value: value, updatedAt: updatedAt)
        }
    }

    private func fetchEnvelopes<T: Codable>(_ type: T.Type, at collection: CollectionReference) async throws -> [String: T]? {
        let snapshot = try await collection.getDocuments()
        guard !snapshot.documents.isEmpty else { return nil }
        var result: [String: T] = [:]
        for document in snapshot.documents {
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
}

private struct SyncEnvelope<T: Codable>: Codable {
    var id: String
    var value: T
    var updatedAt: Date
}

struct FirestoreSyncRecord<Value> {
    var id: String
    var value: Value
    var updatedAt: Date
}

enum FirestoreSyncMerge {
    static func merge<Value>(
        local: [Value],
        remote: [FirestoreSyncRecord<Value>],
        id: (Value) -> String,
        localUpdatedAt: (Value) -> Date?
    ) -> (values: [Value], timestamps: [String: Date]) {
        var orderedIDs: [String] = []
        var valuesByID: [String: Value] = [:]
        var timestampsByID: [String: Date] = [:]

        for value in local {
            let valueID = id(value)
            orderedIDs.append(valueID)
            valuesByID[valueID] = value
            timestampsByID[valueID] = localUpdatedAt(value) ?? .distantPast
        }

        for record in remote {
            let localTimestamp = timestampsByID[record.id]
            if localTimestamp == nil {
                orderedIDs.append(record.id)
                valuesByID[record.id] = record.value
                timestampsByID[record.id] = record.updatedAt
                continue
            }

            if record.updatedAt >= (localTimestamp ?? .distantPast) {
                valuesByID[record.id] = record.value
                timestampsByID[record.id] = record.updatedAt
            }
        }

        let values = orderedIDs.compactMap { valuesByID[$0] }
        return (values, timestampsByID)
    }
}

enum SyncTimestampStore {
    private static let prefix = "yd_firestore_sync_timestamps_"

    static func updatedAt(collection: String, id: String) -> Date? {
        load(collection: collection)[id]
    }

    static func update(collection: String, timestamps: [String: Date]) {
        guard !timestamps.isEmpty else { return }
        var existing = load(collection: collection)
        existing.merge(timestamps) { _, new in new }
        save(existing, collection: collection)
    }

    private static func load(collection: String) -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: prefix + collection),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ timestamps: [String: Date], collection: String) {
        guard let data = try? JSONEncoder().encode(timestamps) else { return }
        UserDefaults.standard.set(data, forKey: prefix + collection)
    }
}
