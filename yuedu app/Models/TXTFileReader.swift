import Foundation

enum TXTFileReader {
    /// 多編碼嘗試讀取 TXT：UTF-8 → BIG5 → GBK → 系統自動偵測
    static func readTextFile(url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        let big5 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
        if let text = try? String(contentsOf: url, encoding: big5) {
            return text
        }

        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = try? String(contentsOf: url, encoding: gbk) {
            return text
        }

        var usedEncoding: String.Encoding = .utf8
        if let text = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            return text
        }

        throw TXTFileReaderError.encodingNotSupported
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
