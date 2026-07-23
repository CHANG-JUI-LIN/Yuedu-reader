import Foundation

enum TXTInitialPreviewPlanner {
    static let maximumByteCount = 64 * 1024

    static func byteCount(
        fileByteCount: Int,
        encoding: String.Encoding
    ) -> Int {
        let bounded = min(max(0, fileByteCount), maximumByteCount)
        guard encoding == .utf16LittleEndian || encoding == .utf16BigEndian else {
            return bounded
        }
        return bounded - (bounded % 2)
    }
}
