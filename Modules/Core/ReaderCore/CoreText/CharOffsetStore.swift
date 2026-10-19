import Foundation
import os

// charOffset is based on NSAttributedString UTF-16 length, aligned with NSRange/CFRange.
// A single emoji (e.g. 👨‍👩‍👧‍👦) may span 10 units in NSRange. Do not use Swift String.count.
struct CharOffsetRecord: Codable, Equatable {
    let bookId: String
    let spineIndex: Int
    let charOffset: Int
    let timestamp: Date
}

final class CharOffsetStore: Sendable {
    /// The record waiting for its debounce, and which `save` scheduled the debounce that may
    /// write it: a newer `save` or a flush bumps `generation`, which cancels the older timer.
    private struct PendingState: Sendable {
        var record: CharOffsetRecord?
        var generation = 0
    }

    private let queue = DispatchQueue(label: "com.yuedu.charoffset", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let directoryURL: URL
    private let pending = OSAllocatedUnfairLock(initialState: PendingState())
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
            let generation = self.pending.withLock { state in
                state.record = record
                state.generation += 1
                return state.generation
            }
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval) { [weak self] in
                guard let self else { return }
                let due = self.pending.withLock { state -> CharOffsetRecord? in
                    guard state.generation == generation, let r = state.record else { return nil }
                    state.record = nil
                    return r
                }
                if let due { self.write(due) }
            }
            self.log("saveQueued bookId=\(record.bookId) spine=\(record.spineIndex) charOffset=\(record.charOffset) debounce=\(self.debounceInterval)")
        }
    }

    func flushSync() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            if let r = takePending() {
                write(r)
                log("flushSync(inQueue) wrotePending bookId=\(r.bookId) spine=\(r.spineIndex) charOffset=\(r.charOffset)")
            } else {
                log("flushSync(inQueue) noPending")
            }
            return
        }

        queue.sync {
            if let r = self.takePending() {
                self.write(r)
                self.log("flushSync wrotePending bookId=\(r.bookId) spine=\(r.spineIndex) charOffset=\(r.charOffset)")
            } else {
                self.log("flushSync noPending")
            }
        }
    }

    /// Takes the waiting record and cancels its debounce timer.
    private func takePending() -> CharOffsetRecord? {
        pending.withLock { state in
            state.generation += 1
            defer { state.record = nil }
            return state.record
        }
    }

    func load(bookId: String) -> CharOffsetRecord? {
        // Must be called from outside queue to avoid deadlock.
        // Synchronises with queue to ensure any pending flushSync writes are visible.
        queue.sync { () -> CharOffsetRecord? in
            let url = self.fileURL(for: bookId)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                self.log("load miss bookId=\(bookId)")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(CharOffsetRecord.self, from: data) {
                self.log("load hit bookId=\(bookId) spine=\(decoded.spineIndex) charOffset=\(decoded.charOffset)")
                return decoded
            } else {
                self.log("load decodeFailed bookId=\(bookId)")
                return nil
            }
        }
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
