import Foundation

// charOffset 基準：NSAttributedString UTF-16 length，與 NSRange/CFRange 對齊。
// 一個 Emoji（如 👨‍👩‍👧‍👦）在 NSRange 可能佔 10 個長度，請勿用 Swift String.count。
struct CharOffsetRecord: Codable, Equatable {
    let bookId: String
    let spineIndex: Int
    let charOffset: Int
    let timestamp: Date
}

final class CharOffsetStore {
    private let queue = DispatchQueue(label: "com.yuedu.charoffset", qos: .utility)
    private let directoryURL: URL
    private var pending: CharOffsetRecord?
    private var debounceWork: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    init(directoryURL: URL, debounceInterval: TimeInterval = 1.0) {
        self.directoryURL = directoryURL
        self.debounceInterval = debounceInterval
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
    }

    func save(_ record: CharOffsetRecord) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending = record
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let r = self.pending else { return }
                self.pending = nil
                self.write(r)
            }
            self.debounceWork = work
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }
    }

    func flushSync() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync { [weak self] in
            guard let self else { return }
            self.debounceWork?.cancel()
            self.debounceWork = nil
            if let r = self.pending {
                self.pending = nil
                self.write(r)
            }
        }
    }

    func load(bookId: String) -> CharOffsetRecord? {
        // Must be called from outside queue to avoid deadlock.
        // Synchronises with queue to ensure any pending flushSync writes are visible.
        var result: CharOffsetRecord?
        queue.sync {
            let url = self.fileURL(for: bookId)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            result = try? decoder.decode(CharOffsetRecord.self, from: data)
        }
        return result
    }

    private func write(_ record: CharOffsetRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        do {
            try data.write(to: fileURL(for: record.bookId), options: .atomic)
        } catch {
            // Silent failure is hard to diagnose; log for production debugging.
            print("[CharOffsetStore] write failed for bookId \(record.bookId): \(error)")
        }
    }

    private func fileURL(for bookId: String) -> URL {
        directoryURL.appendingPathComponent("\(bookId).json")
    }
}
