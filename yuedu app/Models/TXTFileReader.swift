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

    static func readMappedTextFile(url: URL) throws -> TXTMappedTextFile {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let encoding = detectEncoding(from: data)
        return TXTMappedTextFile(data: data, encoding: encoding)
    }

    /// 多編碼嘗試讀取 TXT：UTF-8 → BIG5 → GBK → 系統自動偵測
    static func readTextFile(url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        if let text = try? String(contentsOf: url, encoding: big5Encoding) {
            return text
        }

        if let text = try? String(contentsOf: url, encoding: gbkEncoding) {
            return text
        }

        var usedEncoding: String.Encoding = .utf8
        if let text = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            return text
        }

        throw TXTFileReaderError.encodingNotSupported
    }

    private static func detectEncoding(from data: Data) -> String.Encoding {
        // BOM 優先
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        }

        let sampleCount = min(data.count, 128 * 1024)
        let sample = Data(data.prefix(sampleCount))
        let candidates: [String.Encoding] = [.utf8, big5Encoding, gbkEncoding, .utf16LittleEndian, .utf16BigEndian]
        for encoding in candidates {
            if String(data: sample, encoding: encoding) != nil {
                return encoding
            }
        }
        return .utf8
    }
}

enum TXTFileReaderError: LocalizedError {
    case encodingNotSupported

    var errorDescription: String? {
        switch self {
        case .encodingNotSupported:
            return "無法偵測檔案編碼，請確認為 UTF-8、BIG5 或 GBK 格式"
        }
    }
}
