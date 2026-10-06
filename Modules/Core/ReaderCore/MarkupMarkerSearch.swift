import Foundation

/// Byte-level search for the ASCII markers the online-chapter pipeline keeps looking for
/// (`<img`, `<comment`, `ydreview://`, `showCmt(`, `,{` …).
///
/// `range(of:options: .caseInsensitive)`, `lowercased()` and `components(separatedBy:)` put every
/// character of the document through Unicode case mapping and grapheme breaking. A 段評 chapter
/// is 400–650KB of markup around 3KB of prose (each bubble carries its SVG and its click
/// payload), so one such scan costs ~30ms, and the pipeline made dozens per chapter — measured
/// 2026-10-06 on a 60-bubble 光遇 chapter: ~0.5s of its 1.1s post-processing was these scans and
/// the counting log lines built on them. The markers are ASCII, so folding only ASCII letters
/// while walking the UTF-8 bytes answers the same question in well under a millisecond.
///
/// `needle` is ASCII. Case folding never touches a non-ASCII byte, so a needle that does carry
/// non-ASCII characters only ever matches it exactly.
extension StringProtocol {
    /// Whether `needle` occurs in the receiver.
    func containsMarker(_ needle: String, ignoringCase: Bool = false) -> Bool {
        rangeOfMarker(needle, ignoringCase: ignoringCase) != nil
    }

    /// Non-overlapping occurrences counted left to right — the count
    /// `components(separatedBy: needle).count - 1` reports.
    func countMarkers(_ needle: String, ignoringCase: Bool = false) -> Int {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return 0 }
        return withMarkerBytes { bytes in
            var count = 0
            var offset = 0
            while let found = MarkerSearch.find(pattern, in: bytes, from: offset, ignoringCase: ignoringCase) {
                count += 1
                offset = found + pattern.count
            }
            return count
        }
    }

    /// The first occurrence at or after `start` (the beginning when nil).
    func rangeOfMarker(
        _ needle: String, ignoringCase: Bool = false, from start: Index? = nil
    ) -> Range<Index>? {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return nil }
        let startOffset = start.map { utf8.distance(from: utf8.startIndex, to: $0) } ?? 0
        guard let found = withMarkerBytes({ bytes in
            MarkerSearch.find(pattern, in: bytes, from: startOffset, ignoringCase: ignoringCase)
        }) else { return nil }
        let lower = utf8.index(utf8.startIndex, offsetBy: found)
        return lower..<utf8.index(lower, offsetBy: pattern.count)
    }

    private func withMarkerBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let result = utf8.withContiguousStorageIfAvailable(body) { return result }
        // A bridged NSString has no contiguous UTF-8; one copy is still far cheaper than the
        // Unicode-aware searches this replaces.
        return Array(utf8).withUnsafeBufferPointer(body)
    }
}

enum MarkerSearch {
    /// Offset of the first match of `pattern` in `bytes` at or after `start`.
    static func find(
        _ pattern: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from start: Int, ignoringCase: Bool
    ) -> Int? {
        let count = pattern.count
        guard count > 0, start >= 0, bytes.count - start >= count else { return nil }
        let last = bytes.count - count
        var index = start
        if ignoringCase {
            let first = asciiLowercased(pattern[0])
            while index <= last {
                if asciiLowercased(bytes[index]) == first {
                    var matched = 1
                    while matched < count,
                          asciiLowercased(bytes[index + matched]) == asciiLowercased(pattern[matched]) {
                        matched += 1
                    }
                    if matched == count { return index }
                }
                index += 1
            }
        } else {
            let first = pattern[0]
            while index <= last {
                if bytes[index] == first {
                    var matched = 1
                    while matched < count, bytes[index + matched] == pattern[matched] {
                        matched += 1
                    }
                    if matched == count { return index }
                }
                index += 1
            }
        }
        return nil
    }

    @inline(__always)
    static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
    }
}
