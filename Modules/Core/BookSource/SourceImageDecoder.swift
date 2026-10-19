import Foundation
import os

// MARK: - Source image decode runner

/// Runs a source's `coverDecodeJs` / `ruleContent.imageDecode` over downloaded
/// image bytes (Legado `ImageUtils.decode` semantics: the JS receives `result`
/// as a byte array plus `src`, and returns the decoded bytes).
///
/// Decode runs on the source's shared `BookSourceSession` bridge (JS context +
/// jsLib already warm from detail/TOC/chapter parsing), so the per-image cost
/// is one JS call, not an engine boot. Decode failures return nil and callers
/// keep the original bytes — a broken rule should degrade to "image looks
/// wrong", never to "image disappears".
enum SourceImageDecoder {

    static func decode(_ data: Data, src: String, ruleJs: String, source: BookSource) -> Data? {
        guard !data.isEmpty,
              !ruleJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return BookSourceSession.session(for: source).withBridge { bridge in
            bridge.decodeImageBytes(data, src: src, ruleJs: ruleJs)
        }
    }
}

// MARK: - Cover decode registry

/// Cover-URL → source mapping for sources that declare `coverDecodeJs`, so
/// `BookCoverLoader` (which only sees a URL) can decrypt bytes after download.
/// Only decode-enabled sources register; the overwhelming majority of covers
/// never enter this table.
final class CoverDecodeService: Sendable {
    static let shared = CoverDecodeService()

    private let urlToSourceId = OSAllocatedUnfairLock<[String: UUID]>(initialState: [:])
    private let capacity = 2000

    /// Cheap no-op unless the source actually declares `coverDecodeJs`.
    func registerIfNeeded(coverUrl: String, source: BookSource?) {
        guard let source,
              !coverUrl.isEmpty,
              !source.coverDecodeJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let capacity = capacity
        let sourceId = source.id
        urlToSourceId.withLock { table in
            if table.count >= capacity {
                table.removeAll(keepingCapacity: true)
            }
            table[coverUrl] = sourceId
        }
    }

    /// Decoded bytes when this URL belongs to a registered decode-enabled
    /// source; nil = not registered or decode failed (caller keeps originals).
    func decodedIfRegistered(coverUrl: String, data: Data) -> Data? {
        let sourceId = urlToSourceId.withLock { $0[coverUrl] }
        guard let sourceId,
              let source = BookSourceStore.shared.source(id: sourceId)
        else { return nil }
        let ruleJs = source.coverDecodeJs
        guard !ruleJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SourceImageDecoder.decode(data, src: coverUrl, ruleJs: ruleJs, source: source)
    }
}
