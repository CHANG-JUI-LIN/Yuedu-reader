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
    private let queueKey = DispatchSpecificKey<Void>()
    private let directoryURL: URL
    private var pending: CharOffsetRecord?
    private var debounceWork: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    private func log(_ message: String) {
        print("[ProgressTrace][CharOffsetStore] \(message)")
    }

    init(directoryURL: URL, debounceInterval: TimeInterval = 1.0) {
        self.directoryURL = directoryURL
        self.debounceInterval = debounceInterval
        queue.setSpecific(key: queueKey, value: ())
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
    }

    deinit {
        flushSync()
    }

    func save(_ record: CharOffsetRecord) {
        queue.async { [self] in
            self.pending = record
            self.debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let r = self.pending else { return }
                self.pending = nil
                self.write(r)
            }
            self.debounceWork = work
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
            self.log("saveQueued bookId=\(record.bookId) spine=\(record.spineIndex) charOffset=\(record.charOffset) debounce=\(self.debounceInterval)")
        }
    }

    func flushSync() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            debounceWork?.cancel()
            debounceWork = nil
            if let r = pending {
                pending = nil
                write(r)
                log("flushSync(inQueue) wrotePending bookId=\(r.bookId) spine=\(r.spineIndex) charOffset=\(r.charOffset)")
            } else {
                log("flushSync(inQueue) noPending")
            }
            return
        }

        queue.sync {
            self.debounceWork?.cancel()
            self.debounceWork = nil
            if let r = self.pending {
                self.pending = nil
                self.write(r)
                self.log("flushSync wrotePending bookId=\(r.bookId) spine=\(r.spineIndex) charOffset=\(r.charOffset)")
            } else {
                self.log("flushSync noPending")
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
                  let data = try? Data(contentsOf: url) else {
                self.log("load miss bookId=\(bookId)")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(CharOffsetRecord.self, from: data) {
                result = decoded
                self.log("load hit bookId=\(bookId) spine=\(decoded.spineIndex) charOffset=\(decoded.charOffset)")
            } else {
                self.log("load decodeFailed bookId=\(bookId)")
            }
        }
        return result
    }

    private func write(_ record: CharOffsetRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: record.bookId), options: .atomic)
            log("write success bookId=\(record.bookId) spine=\(record.spineIndex) charOffset=\(record.charOffset)")
        } catch {
            // Silent failure is hard to diagnose; log for production debugging.
            print("[CharOffsetStore] write failed for bookId \(record.bookId): \(error)")
        }
    }

    private func fileURL(for bookId: String) -> URL {
        directoryURL.appendingPathComponent("\(safeFileStem(for: bookId)).json")
    }

    private func safeFileStem(for bookId: String) -> String {
        let encoded = Data(bookId.utf8).base64EncodedString()
        return encoded
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
