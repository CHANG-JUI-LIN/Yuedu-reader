import CryptoKit
import Foundation

struct TXTMappedTextFile: Sendable {
    let data: Data
    let encoding: String.Encoding

    var byteCount: Int { data.count }

    func string(in byteRange: Range<Int>) -> String {
        let lower = max(0, min(byteRange.lowerBound, data.count))
        let upper = max(lower, min(byteRange.upperBound, data.count))
        guard lower < upper else { return "" }
        let chunk = data.subdata(in: lower..<upper)
        if let decoded = TXTTextDecoder.decode(chunk, as: encoding) {
            return decoded
        }
        AppLogger.error("TXT mapped range decode failed", context: [
            "encoding": encoding.rawValue, "lowerByte": lower, "upperByte": upper,
        ])
        return String(decoding: chunk, as: UTF8.self)
    }
}

enum TXTFileReader {
    static let gb18030Encoding = TXTEncodingDetector.Multibyte.gb18030.encoding

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
        // Detection stays bounded even for a memory-mapped multi-gigabyte book.
        let encoding = try detectEncoding(fromSample: data.prefix(TXTEncodingDetector.maximumSampleBytes))
        return TXTMappedTextFile(data: data, encoding: encoding)
    }

    /// Sample first, then read the whole file once with the selected encoding.
    static func readTextFile(url: URL) throws -> String {
        let encoding = try detectEncodingBySampling(url: url)
        return try string(contentsOf: url, encoding: encoding)
    }

    static func detectEncodingBySampling(url: URL) throws -> String.Encoding {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() }
            catch { AppLogger.error("TXT file handle close failed", error: error) }
        }
        let sample = try handle.read(upToCount: TXTEncodingDetector.maximumSampleBytes) ?? Data()
        return try detectEncoding(fromSample: sample)
    }

    /// Decodes only the requested file prefix, using the same bounded encoding
    /// detection as the full TXT reader. The caller controls the hard I/O cap.
    static func readPrefix(url: URL, maxByteCount: Int) throws -> String {
        guard maxByteCount > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do { try handle.close() }
            catch { AppLogger.error("TXT file handle close failed", error: error) }
        }

        let data = try handle.read(upToCount: maxByteCount) ?? Data()
        guard !data.isEmpty else { return "" }
        let detectionSample = data.prefix(TXTEncodingDetector.maximumSampleBytes)
        let encoding = try detectEncoding(fromSample: detectionSample)

        if let decoded = TXTTextDecoder.decode(data, as: encoding) {
            return decoded.trimmingLeadingByteOrderMark()
        }

        // The fixed byte boundary may cut through one multibyte scalar. Match
        // encoding detection's tolerance without reading beyond the hard cap.
        let maxDrop = min(3, data.count - 1)
        if maxDrop >= 1 {
            for drop in 1...maxDrop {
                if let decoded = TXTTextDecoder.decode(Data(data.prefix(data.count - drop)), as: encoding) {
                    return decoded.trimmingLeadingByteOrderMark()
                }
            }
        }
        AppLogger.error("TXT prefix decode failed", context: ["encoding": encoding.rawValue, "bytes": data.count])
        throw TXTFileReaderError.encodingNotSupported
    }

    private static func detectEncoding(fromSample data: Data) throws -> String.Encoding {
        try TXTEncodingDetector.detect(data)
    }

    private static func string(contentsOf url: URL, encoding: String.Encoding) throws -> String {
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard let text = TXTTextDecoder.decode(data, as: encoding) else {
                throw TXTFileReaderError.encodingNotSupported
            }
            return text.trimmingLeadingByteOrderMark()
        } catch {
            AppLogger.error("TXT file decode failed", error: error,
                            context: ["encoding": encoding.rawValue])
            throw error
        }
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
            return localized("TXTEncodingUnsupported")
        }
    }
}
