import Foundation


// MARK: - Unified Reading Locator

struct ReaderLocator: Codable, Equatable {
    let spineHref: String
    let chapterIndex: Int
    let pageInChapter: Int
    let totalPagesInChapter: Int
    let globalPage: Int
    let progression: Double
    let generationId: Int
    let layoutGeneration: Int?
    let title: String?
    let chapterProgression: Double?
    let totalProgression: Double?
    let locatorJSON: String?
    let cssSelector: String?
    let partialCFI: String?
    let domRangeJSON: String?
    let highlightedText: String?
    let timestamp: Date

    init(
        spineHref: String,
        chapterIndex: Int,
        pageInChapter: Int,
        totalPagesInChapter: Int,
        globalPage: Int,
        progression: Double,
        generationId: Int,
        layoutGeneration: Int? = nil,
        title: String? = nil,
        chapterProgression: Double? = nil,
        totalProgression: Double? = nil,
        locatorJSON: String? = nil,
        cssSelector: String? = nil,
        partialCFI: String? = nil,
        domRangeJSON: String? = nil,
        highlightedText: String? = nil,
        timestamp: Date = Date()
    ) {
        self.spineHref = spineHref
        self.chapterIndex = chapterIndex
        self.pageInChapter = pageInChapter
        self.totalPagesInChapter = totalPagesInChapter
        self.globalPage = globalPage
        self.progression = progression
        self.generationId = generationId
        self.layoutGeneration = layoutGeneration
        self.title = title
        self.chapterProgression = chapterProgression
        self.totalProgression = totalProgression
        self.locatorJSON = locatorJSON
        self.cssSelector = cssSelector
        self.partialCFI = partialCFI
        self.domRangeJSON = domRangeJSON
        self.highlightedText = highlightedText
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case spineHref
        case chapterIndex
        case pageInChapter
        case totalPagesInChapter
        case globalPage
        case progression
        case generationId
        case layoutGeneration
        case title
        case chapterProgression
        case totalProgression
        case locatorJSON
        case cssSelector
        case partialCFI
        case domRangeJSON
        case highlightedText
        case timestamp

        // Legacy keys.
        case href
        case position
        case spineIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let legacyHref = try container.decodeIfPresent(String.self, forKey: .href)
        let legacyPosition = try container.decodeIfPresent(Int.self, forKey: .position)
        let legacySpineIndex = try container.decodeIfPresent(Int.self, forKey: .spineIndex)

        spineHref = try container.decodeIfPresent(String.self, forKey: .spineHref) ?? legacyHref ?? ""
        chapterIndex = try container.decodeIfPresent(Int.self, forKey: .chapterIndex) ?? legacySpineIndex ?? 0
        pageInChapter = try container.decodeIfPresent(Int.self, forKey: .pageInChapter) ?? legacyPosition ?? 0
        totalPagesInChapter = try container.decodeIfPresent(Int.self, forKey: .totalPagesInChapter) ?? 1
        globalPage = try container.decodeIfPresent(Int.self, forKey: .globalPage) ?? 0
        progression = try container.decodeIfPresent(Double.self, forKey: .progression) ?? 0
        generationId = try container.decodeIfPresent(Int.self, forKey: .generationId) ?? 0
        layoutGeneration = try container.decodeIfPresent(Int.self, forKey: .layoutGeneration)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        chapterProgression = try container.decodeIfPresent(Double.self, forKey: .chapterProgression)
        totalProgression = try container.decodeIfPresent(Double.self, forKey: .totalProgression)
        locatorJSON = try container.decodeIfPresent(String.self, forKey: .locatorJSON)
        cssSelector = try container.decodeIfPresent(String.self, forKey: .cssSelector)
        partialCFI = try container.decodeIfPresent(String.self, forKey: .partialCFI)
        domRangeJSON = try container.decodeIfPresent(String.self, forKey: .domRangeJSON)
        highlightedText = try container.decodeIfPresent(String.self, forKey: .highlightedText)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spineHref, forKey: .spineHref)
        try container.encode(chapterIndex, forKey: .chapterIndex)
        try container.encode(pageInChapter, forKey: .pageInChapter)
        try container.encode(totalPagesInChapter, forKey: .totalPagesInChapter)
        try container.encode(globalPage, forKey: .globalPage)
        try container.encode(progression, forKey: .progression)
        try container.encode(generationId, forKey: .generationId)
        try container.encodeIfPresent(layoutGeneration, forKey: .layoutGeneration)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(chapterProgression, forKey: .chapterProgression)
        try container.encodeIfPresent(totalProgression, forKey: .totalProgression)
        try container.encodeIfPresent(locatorJSON, forKey: .locatorJSON)
        try container.encodeIfPresent(cssSelector, forKey: .cssSelector)
        try container.encodeIfPresent(partialCFI, forKey: .partialCFI)
        try container.encodeIfPresent(domRangeJSON, forKey: .domRangeJSON)
        try container.encodeIfPresent(highlightedText, forKey: .highlightedText)
        try container.encode(timestamp, forKey: .timestamp)
    }

    var href: String { spineHref }
    var position: Int? { pageInChapter }
    var spineIndex: Int? { chapterIndex }
}


typealias SnapshotLocator = ReaderLocator
typealias LocatorRecord = ReaderLocator

// MARK: - Progress Storage

final class EPUBProgressStore {
    private let queue = DispatchQueue(label: "com.yuedu.epub-progress", qos: .utility)
    private let directoryURL: URL
    private var pendingRecord: ReaderLocator?
    private var debounceWork: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    init(directoryURL: URL, debounceInterval: TimeInterval = 1.0) {
        self.directoryURL = directoryURL
        self.debounceInterval = debounceInterval
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
    }

    func save(record: ReaderLocator) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingRecord = record
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let record = self.pendingRecord else { return }
                self.pendingRecord = nil
                self.write(record: record)
            }
            self.debounceWork = work
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }
    }

    func flushSync() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.debounceWork?.cancel()
            self.debounceWork = nil
            if let record = self.pendingRecord {
                self.pendingRecord = nil
                self.write(record: record)
            }
        }
    }

    func loadLastRecord() -> ReaderLocator? {
        let url = directoryURL.appendingPathComponent("last_progress.json")
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReaderLocator.self, from: data)
    }

    private func write(record: ReaderLocator) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            let historyURL = directoryURL.appendingPathComponent("progress_history.ndjson")
            let lineData = data + Data([0x0A])

            if FileManager.default.fileExists(atPath: historyURL.path) {
                let handle = try FileHandle(forWritingTo: historyURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: historyURL, options: .atomic)
            }

            let lastURL = directoryURL.appendingPathComponent("last_progress.json")
            try data.write(to: lastURL, options: .atomic)
        } catch {
        }
    }
}
