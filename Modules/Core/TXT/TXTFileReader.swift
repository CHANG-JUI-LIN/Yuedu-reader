import CryptoKit
import Foundation

struct TXTMappedTextFile {
    let data: Data
    let encoding: String.Encoding

    var byteCount: Int { data.count }

    func string(in byteRange: Range<Int>) -> String {
        let lower = max(0, min(byteRange.lowerBound, data.count))
        let upper = max(lower, min(byteRange.upperBound, data.count))
        guard lower < upper else { return "" }
        let chunk = data.subdata(in: lower..<upper)
        if let decoded = String(data: chunk, encoding: encoding) {
            return decoded
        }
        return String(decoding: chunk, as: UTF8.self)
    }
}

enum TXTFileReader {
    private static let big5Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)))

    private static let gbkEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static let gb18030Encoding = gbkEncoding

    static func fileFingerprint(data: Data) -> String {
        // Take first 64KB + last 64KB, hash with MD5
        let prefixSize = min(65536, data.count)
        let suffixSize = min(65536, max(0, data.count - prefixSize))
        var hasher = CryptoKit.Insecure.MD5()
        data.prefix(prefixSize).withUnsafeBytes { hasher.update(bufferPointer: $0) }
        if suffixSize > 0 {
            data.suffix(suffixSize).withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined() + "_\(data.count)"
    }

    static func readMappedTextFile(url: URL) throws -> TXTMappedTextFile {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        // Detect from a bounded sample: feeding the whole mapped file into
        // String(data:) meant up to five full-file trial decodes on a large book
        // just to pick the charset. 512KB matches Legado's detection window;
        // `canDecode` already tolerates the truncated trailing character.
        let encoding = detectEncoding(fromSample: data.prefix(512 * 1024))
        return TXTMappedTextFile(data: data, encoding: encoding)
    }

    /// Sample first, then read the whole file once with the selected encoding.
    static func readTextFile(url: URL) throws -> String {
        let encoding = try detectEncodingBySampling(url: url)
        return try string(contentsOf: url, encoding: encoding)
    }

    static func detectEncodingBySampling(url: URL) throws -> String.Encoding {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sample = try handle.read(upToCount: 8192) ?? Data()
        return detectEncoding(fromSample: sample)
    }

    private static func detectEncoding(fromSample data: Data) -> String.Encoding {
        // BOM first
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        }

        let candidates: [String.Encoding] = [.utf8, gbkEncoding, big5Encoding, .utf16LittleEndian, .utf16BigEndian]
        for encoding in candidates {
            if canDecode(data, as: encoding) {
                return encoding
            }
        }
        return .utf8
    }

    /// Whether `data` decodes cleanly with `encoding`, tolerating an incomplete
    /// multibyte sequence at the very end of the buffer.
    ///
    /// Detection runs on a fixed-size sample (e.g. the first 8KB), so the sample
    /// boundary frequently lands in the middle of a multibyte character. Without
    /// this tolerance a valid UTF-8 file is wrongly rejected and detection falls
    /// through to GBK/Big5/UTF-16, producing garbled text.
    private static func canDecode(_ data: Data, as encoding: String.Encoding) -> Bool {
        if String(data: data, encoding: encoding) != nil {
            return true
        }
        // A truncated trailing character is at most 3 bytes short of complete
        // (UTF-8 sequences run up to 4 bytes). Retry while dropping those bytes.
        let maxDrop = min(3, data.count - 1)
        guard maxDrop >= 1 else { return false }
        for drop in 1...maxDrop {
            let trimmed = data.prefix(data.count - drop)
            if String(data: trimmed, encoding: encoding) != nil {
                return true
            }
        }
        return false
    }

    private static func string(contentsOf url: URL, encoding: String.Encoding) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: encoding) else {
            throw TXTFileReaderError.encodingNotSupported
        }
        return text.trimmingLeadingByteOrderMark()
    }
}

private extension String {
    func trimmingLeadingByteOrderMark() -> String {
        guard unicodeScalars.first == "\u{FEFF}" else { return self }
        return String(unicodeScalars.dropFirst())
    }
}

enum TXTFileReaderError: LocalizedError {
    case encodingNotSupported

    var errorDescription: String? {
        switch self {
        case .encodingNotSupported:
            return "Unable to detect file encoding; please ensure UTF-8, BIG5, or GBK format"
        }
    }
}
