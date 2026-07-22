import Foundation

enum OfflineChapterSelection: Sendable, Equatable {
    case range(ClosedRange<Int>)
    case indices(Set<Int>)
    case single(Int)

    var indices: Set<Int> {
        switch self {
        case .range(let range):
            return Set(range.filter { $0 >= 0 })
        case .indices(let indices):
            return Set(indices.filter { $0 >= 0 })
        case .single(let index):
            return index >= 0 ? [index] : []
        }
    }
}

struct OfflineChapterFailure: Codable, Equatable, Sendable {
    enum Category: String, Codable, Sendable {
        case invalidChapter
        case network
        case parsing
        case emptyContent
        case textWrite
        case imageDownload
        case imageValidation
        case canceled
        case unknown
    }

    var chapterIndex: Int
    var title: String
    var category: Category
    var message: String
    var occurredAt: Date
}

struct BookOfflineDownloadTask: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var requestedIndices: Set<Int>
    var pendingIndices: Set<Int>
    var completedIndices: Set<Int>
    var failedChapters: [Int: OfflineChapterFailure]
    var isPaused: Bool
    var startedAt: Date
    var updatedAt: Date

    init(requestedIndices: Set<Int>, isPaused: Bool = false, now: Date = Date()) {
        let normalized = Set(requestedIndices.filter { $0 >= 0 })
        schemaVersion = Self.currentSchemaVersion
        self.requestedIndices = normalized
        pendingIndices = normalized
        completedIndices = []
        failedChapters = [:]
        self.isPaused = isPaused
        startedAt = now
        updatedAt = now
    }

    /// Compatibility initializer for call sites that still supply the legacy range.
    /// Legacy values decoded from disk use the custom decoder below and never trust
    /// `completedChapterCount` as proof that an artifact exists.
    init(
        startChapterIndex: Int,
        endChapterIndex: Int,
        completedChapterCount: Int = 0,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let start = max(0, startChapterIndex)
        let end = max(start, endChapterIndex)
        let requested = Set(start...end)
        let completed = Set(requested.sorted().prefix(max(0, completedChapterCount)))

        schemaVersion = Self.currentSchemaVersion
        requestedIndices = requested
        completedIndices = completed
        pendingIndices = requested.subtracting(completed)
        failedChapters = [:]
        isPaused = false
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    var startChapterIndex: Int {
        requestedIndices.min() ?? 0
    }

    var endChapterIndex: Int {
        requestedIndices.max() ?? startChapterIndex
    }

    var completedChapterCount: Int {
        completedIndices.intersection(requestedIndices).count
    }

    var totalChapterCount: Int {
        requestedIndices.count
    }

    var clampedCompletedChapterCount: Int {
        min(max(completedChapterCount, 0), totalChapterCount)
    }

    mutating func mergeRequestedIndices(_ indices: Set<Int>, now: Date = Date()) {
        let additions = Set(indices.filter { $0 >= 0 }).subtracting(requestedIndices)
        requestedIndices.formUnion(additions)
        pendingIndices.formUnion(additions)
        updatedAt = now
    }

    mutating func markCompleted(_ index: Int, now: Date = Date()) {
        guard index >= 0 else { return }
        requestedIndices.insert(index)
        pendingIndices.remove(index)
        failedChapters.removeValue(forKey: index)
        completedIndices.insert(index)
        updatedAt = now
    }

    mutating func markFailed(_ failure: OfflineChapterFailure) {
        guard failure.chapterIndex >= 0 else { return }
        requestedIndices.insert(failure.chapterIndex)
        pendingIndices.remove(failure.chapterIndex)
        completedIndices.remove(failure.chapterIndex)
        failedChapters[failure.chapterIndex] = failure
        updatedAt = failure.occurredAt
    }

    mutating func retryFailedIndices(now: Date = Date()) {
        pendingIndices.formUnion(failedChapters.keys)
        failedChapters.removeAll()
        isPaused = false
        updatedAt = now
    }

    mutating func setPaused(_ paused: Bool, now: Date = Date()) {
        isPaused = paused
        updatedAt = now
    }

    mutating func markPending(_ index: Int, now: Date = Date()) {
        guard index >= 0, requestedIndices.contains(index) else { return }
        completedIndices.remove(index)
        failedChapters.removeValue(forKey: index)
        pendingIndices.insert(index)
        updatedAt = now
    }

    mutating func removeRequestedIndices(_ indices: Set<Int>, now: Date = Date()) {
        requestedIndices.subtract(indices)
        pendingIndices.subtract(indices)
        completedIndices.subtract(indices)
        for index in indices {
            failedChapters.removeValue(forKey: index)
        }
        updatedAt = now
    }

    func derivedState(isRunning: Bool) -> BookOfflineDownloadState {
        if isPaused && !pendingIndices.isEmpty { return .paused }
        if isRunning || !pendingIndices.isEmpty { return .downloading }
        if !failedChapters.isEmpty || completedIndices.count < requestedIndices.count {
            return .partial
        }
        return requestedIndices.isEmpty ? .none : .available
    }

    /// Temporary compatibility helper used by the legacy coordinator until the
    /// queue manager is installed. Progress is still represented as exact indices.
    func updatingProgress(_ completed: Int, at date: Date = Date()) -> BookOfflineDownloadTask {
        var copy = self
        let completedSet = Set(copy.requestedIndices.sorted().prefix(max(0, completed)))
        copy.completedIndices.formUnion(completedSet)
        copy.pendingIndices = copy.requestedIndices
            .subtracting(copy.completedIndices)
            .subtracting(Set(copy.failedChapters.keys))
        copy.updatedAt = date
        return copy
    }

    func clamped(to chapterCount: Int) -> BookOfflineDownloadTask? {
        guard chapterCount > 0 else { return nil }
        var copy = self
        copy.requestedIndices = Set(requestedIndices.filter { $0 < chapterCount })
        guard !copy.requestedIndices.isEmpty else { return nil }
        copy.completedIndices.formIntersection(copy.requestedIndices)
        copy.pendingIndices.formIntersection(copy.requestedIndices)
        copy.failedChapters = copy.failedChapters.filter { copy.requestedIndices.contains($0.key) }
        let accounted = copy.completedIndices
            .union(copy.pendingIndices)
            .union(copy.failedChapters.keys)
        copy.pendingIndices.formUnion(copy.requestedIndices.subtracting(accounted))
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestedIndices
        case pendingIndices
        case completedIndices
        case failedChapters
        case isPaused
        case startedAt
        case updatedAt
        case startChapterIndex
        case endChapterIndex
        case completedChapterCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.requestedIndices) {
            schemaVersion = Self.currentSchemaVersion
            let decodedRequestedIndices = Set(
                try container.decode(Set<Int>.self, forKey: .requestedIndices)
                    .filter { $0 >= 0 }
            )
            requestedIndices = decodedRequestedIndices
            pendingIndices = Set(
                try container.decodeIfPresent(Set<Int>.self, forKey: .pendingIndices) ?? []
            ).intersection(decodedRequestedIndices)
            completedIndices = Set(
                try container.decodeIfPresent(Set<Int>.self, forKey: .completedIndices) ?? []
            ).intersection(decodedRequestedIndices)
            failedChapters = (try container.decodeIfPresent(
                [Int: OfflineChapterFailure].self,
                forKey: .failedChapters
            ) ?? [:]).filter { decodedRequestedIndices.contains($0.key) }
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt

            completedIndices.subtract(Set(failedChapters.keys))
            pendingIndices.subtract(completedIndices)
            pendingIndices.subtract(Set(failedChapters.keys))
            let accounted = completedIndices.union(pendingIndices).union(failedChapters.keys)
            pendingIndices.formUnion(requestedIndices.subtracting(accounted))
            return
        }

        let start = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .startChapterIndex) ?? 0
        )
        let legacyEnd = try container.decodeIfPresent(Int.self, forKey: .endChapterIndex) ?? start
        let end = max(start, legacyEnd)
        let requested = Set(start...end)

        schemaVersion = Self.currentSchemaVersion
        requestedIndices = requested
        pendingIndices = requested
        completedIndices = []
        failedChapters = [:]
        isPaused = false
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(requestedIndices, forKey: .requestedIndices)
        try container.encode(pendingIndices, forKey: .pendingIndices)
        try container.encode(completedIndices, forKey: .completedIndices)
        try container.encode(failedChapters, forKey: .failedChapters)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
