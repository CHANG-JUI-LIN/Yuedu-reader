import Darwin
import Foundation

/// One decoding entry for detection, previews, full text and mapped chapters.
enum TXTTextDecoder {
    static func decode(_ data: Data, as encoding: String.Encoding) -> String? {
        guard encoding == .japaneseEUC else { return String(data: data, encoding: encoding) }
        if data.isEmpty { return "" }
        // Foundation's japaneseEUC rejects valid JIS X 0212 (8F xx xx).
        // iconv is the primary EUC-JP decoder, including ordinary 0208 and kana;
        // there is no failed-Foundation retry or second TXT reading pipeline.
        guard let converter = iconv_open("UTF-8", "EUC-JP"),
              converter != iconv_t(bitPattern: -1) else {
            AppLogger.error("TXT EUC-JP converter unavailable", context: ["errno": errno])
            return nil
        }
        defer {
            if iconv_close(converter) != 0 {
                AppLogger.error("TXT EUC-JP converter close failed", context: ["errno": errno])
            }
        }
        // EUC-JP's largest expansion is two input bytes to three UTF-8 bytes.
        var output = Data(count: data.count * 2 + 16)
        var remainingInput = data.count
        var remainingOutput = output.count
        let status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                var inputPointer = UnsafeMutablePointer(mutating: input.bindMemory(to: CChar.self).baseAddress)
                var outputPointer = buffer.bindMemory(to: CChar.self).baseAddress
                return iconv(converter, &inputPointer, &remainingInput, &outputPointer, &remainingOutput)
            }
        }
        guard status != -1, remainingInput == 0 else { return nil }
        output.removeLast(remainingOutput)
        return String(data: output, encoding: .utf8)
    }
}
