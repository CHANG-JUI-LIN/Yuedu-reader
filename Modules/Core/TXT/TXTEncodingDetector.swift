import Foundation

/// Statistical recognition informed by Legado's EncodingDetect and ICU4J's
/// CharsetRecog_mbcs/UTF8/Unicode. Both local Legado clones have identical logic.
/// This Swift implementation scans intact encoded characters: standalone ASCII
/// contributes no MBCS evidence, but low trail bytes (CP932/Big5/GB18030) remain.
enum TXTEncodingDetector {
    static let maximumSampleBytes = 512 * 1024
    private static let maximumHighBytes = 8_000
    private static let minimumConfidence = 10

    enum Multibyte: CaseIterable {
        case gb18030, big5, shiftJIS, eucJP, eucKR

        var encoding: String.Encoding {
            let value: CFStringEncodings
            switch self {
            case .gb18030: value = .GB_18030_2000
            case .big5: value = .big5
            case .shiftJIS: value = .dosJapanese // CP932 includes NEC/IBM extensions.
            case .eucJP: value = .EUC_JP
            case .eucKR: value = .EUC_KR
            }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(value.rawValue)))
        }

        var commonCharacters: Set<UInt32> {
            switch self {
            case .gb18030: TXTEncodingFrequencyData.gb18030
            case .big5: TXTEncodingFrequencyData.big5
            case .shiftJIS: TXTEncodingFrequencyData.shiftJIS
            case .eucJP: TXTEncodingFrequencyData.eucJP
            case .eucKR: TXTEncodingFrequencyData.eucKR
            }
        }

        /// Expected width and legality; nil means a truncated trailing character.
        func character(in bytes: [UInt8], at index: Int) -> (width: Int, valid: Bool)? {
            let lead = Int(bytes[index])
            if lead < 0x80 { return (1, true) }
            if self == .shiftJIS, (0xA1...0xDF).contains(lead) { return (1, true) }
            guard index + 1 < bytes.count else { return nil }
            let trail = Int(bytes[index + 1])
            switch self {
            case .shiftJIS:
                return (2, ((0x81...0x9F).contains(lead) || (0xE0...0xFC).contains(lead))
                    && ((0x40...0x7E).contains(trail) || (0x80...0xFC).contains(trail)))
            case .big5:
                return (2, (0x81...0xFE).contains(lead)
                    && ((0x40...0x7E).contains(trail) || (0xA1...0xFE).contains(trail)))
            case .gb18030:
                if (0x81...0xFE).contains(lead), (0x30...0x39).contains(trail) {
                    guard index + 3 < bytes.count else { return nil }
                    return (4, (0x81...0xFE).contains(Int(bytes[index + 2]))
                        && (0x30...0x39).contains(Int(bytes[index + 3])))
                }
                return (2, (0x81...0xFE).contains(lead)
                    && ((0x40...0x7E).contains(trail) || (0x80...0xFE).contains(trail)))
            case .eucJP:
                if lead == 0x8E { return (2, (0xA1...0xDF).contains(trail)) }
                if lead == 0x8F {
                    guard index + 2 < bytes.count else { return nil }
                    return (3, (0xA1...0xFE).contains(trail)
                        && (0xA1...0xFE).contains(Int(bytes[index + 2])))
                }
                return (2, (0xA1...0xFE).contains(lead) && (0xA1...0xFE).contains(trail))
            case .eucKR:
                return (2, (0xA1...0xFE).contains(lead) && (0xA1...0xFE).contains(trail))
            }
        }
    }

    private struct Match {
        let encoding: String.Encoding
        let confidence: Int
        let commonFraction: Double
    }

    static func detect(_ data: Data) throws -> String.Encoding {
        let sample = Data(data.prefix(maximumSampleBytes))
        let bytes = Array(sample)
        let bom: String.Encoding?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bom = .utf8 }
        else if bytes.starts(with: [0xFF, 0xFE]) { bom = .utf16LittleEndian }
        else if bytes.starts(with: [0xFE, 0xFF]) { bom = .utf16BigEndian }
        else { bom = nil }
        if let bom {
            guard canDecode(sample, as: bom) else { return try failure(sample, matches: []) }
            return bom
        }
        // Empty and pure ASCII are unambiguous UTF-8; NUL is evidence for UTF-16.
        if bytes.allSatisfy({ $0 < 0x80 && $0 != 0 }) { return .utf8 }

        var matches: [Match] = []
        if !bytes.contains(0), canDecode(sample, as: .utf8) {
            let starts = bytes.lazy.filter { $0 >= 0xC2 }.prefix(4).count
            matches.append(Match(encoding: .utf8, confidence: starts > 3 ? 100 : 80, commonFraction: 1))
        }
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            let confidence = unicodeConfidence(bytes, littleEndian: encoding == .utf16LittleEndian)
            // ICU's initial 10 means "compatible", not positive UTF-16 evidence.
            if confidence > 10, canDecode(sample, as: encoding) {
                matches.append(Match(encoding: encoding, confidence: confidence, commonFraction: 0))
            }
        }
        for candidate in Multibyte.allCases {
            let match = multibyteMatch(bytes, candidate: candidate)
            if match.confidence >= minimumConfidence, canDecode(sample, as: match.encoding) {
                matches.append(match)
            }
        }
        let ranked = matches.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            // ICU caps scores at 100. Compare frequency density to resolve that
            // saturation instead of letting candidate order decide the language.
            return $0.commonFraction > $1.commonFraction
        }
        guard let best = ranked.first, best.confidence >= minimumConfidence else {
            return try failure(sample, matches: ranked)
        }
        return best.encoding
    }

    private static func unicodeConfidence(_ bytes: [UInt8], littleEndian: Bool) -> Int {
        guard bytes.count >= 4 else { return 0 }
        var confidence = 10
        let limit = min(bytes.count, 30)
        for index in stride(from: 0, to: limit - 1, by: 2) {
            let first = Int(bytes[index]), second = Int(bytes[index + 1])
            let unit = littleEndian ? first | (second << 8) : (first << 8) | second
            if unit == 0 { confidence -= 10 }
            else if (0x20...0xFF).contains(unit) || unit == 0x0A { confidence += 10 }
            confidence = min(100, max(0, confidence))
            if confidence == 0 || confidence == 100 { break }
        }
        return confidence
    }

    private static func multibyteMatch(_ bytes: [UInt8], candidate: Multibyte) -> Match {
        var index = 0, highBytes = 0, multibyte = 0, common = 0, invalid = 0, kana = 0
        let frequencies = candidate.commonCharacters
        while index < bytes.count, highBytes < maximumHighBytes {
            guard let character = candidate.character(in: bytes, at: index) else { break }
            if bytes[index] >= 0x80 {
                var value: UInt32 = 0
                for byte in bytes[index..<(index + character.width)] {
                    value = (value << 8) | UInt32(byte)
                    if byte >= 0x80 { highBytes += 1 }
                }
                if !character.valid { invalid += 1 }
                else if character.width > 1 {
                    multibyte += 1
                    if frequencies.contains(value) { common += 1 }
                } else if candidate == .shiftJIS { kana += 1 }
            }
            index += character.width
            if invalid >= 2, invalid * 5 >= multibyte { break }
        }
        let confidence: Int
        if multibyte < invalid * 20 { confidence = 0 }
        else if multibyte <= 10 {
            // Tiny prefixes must contain actual frequent characters; byte
            // compatibility alone is the cause of the old first-decoder bug.
            confidence = invalid == 0 && common > 0 ? 10 : (invalid == 0 && kana >= 10 ? 30 : 0)
        } else {
            confidence = min(100, Int(log(Double(common + 1)) * 90 / log(Double(multibyte) / 4) + 10))
        }
        return Match(encoding: candidate.encoding, confidence: confidence,
                     commonFraction: Double(common) / Double(max(1, multibyte)))
    }

    /// Fixed samples may cut one scalar. Only the final 1–3 bytes may be omitted;
    /// internal invalid sequences never qualify a candidate for selection.
    static func canDecode(_ data: Data, as encoding: String.Encoding) -> Bool {
        if TXTTextDecoder.decode(data, as: encoding) != nil { return true }
        let maxDrop = min(3, data.count - 1)
        guard maxDrop >= 1 else { return false }
        for drop in 1...maxDrop {
            if TXTTextDecoder.decode(Data(data.prefix(data.count - drop)), as: encoding) != nil { return true }
        }
        return false
    }

    private static func failure(_ sample: Data, matches: [Match]) throws -> String.Encoding {
        AppLogger.error("TXT encoding detection failed", context: [
            "sampleBytes": sample.count, "minimumConfidence": minimumConfidence,
            "candidates": matches.map { "\($0.encoding.rawValue):\($0.confidence)" }.joined(separator: ","),
        ])
        throw TXTFileReaderError.encodingNotSupported
    }
}
