import Foundation

/// Charset detection + decoding for HTTP response bodies.
///
/// This logic used to live as private methods on the `WebFetcher` **actor**, which
/// meant every book source's response was decoded on one serial executor: a
/// 100-source search funnelled 100 full-document decodes through a single lane
/// while the network sat idle. Nothing here touches shared mutable state, so it
/// lives as pure statics that any thread can run concurrently.
///
/// Kept deliberately allocation-light: `decode` is on the hot path of every
/// search, TOC and chapter fetch in the app.
enum HTMLResponseDecoder {

    /// Multi-strategy charset detection with scoring for ambiguous encodings.
    static func decode(data: Data, response: URLResponse) -> String? {
        struct DecodeCandidate {
            let encoding: String.Encoding
            let priority: Int
        }

        var candidates: [DecodeCandidate] = []
        var seen = Set<UInt>()

        func appendCandidate(_ encoding: String.Encoding?, priority: Int) {
            guard let encoding else { return }
            guard seen.insert(encoding.rawValue).inserted else { return }
            candidates.append(DecodeCandidate(encoding: encoding, priority: priority))
        }

        appendCandidate(bomEncoding(in: data), priority: 500)
        appendCandidate(encoding(forIANA: response.textEncodingName), priority: 380)

        if let http = response as? HTTPURLResponse,
            let ct = http.value(forHTTPHeaderField: "Content-Type")
        {
            appendCandidate(encoding(forIANA: charsetInHeader(ct)), priority: 360)
        }

        let sniff = String(data: data.prefix(DecodeScoreWeights.sampleSize), encoding: .isoLatin1) ?? ""
        appendCandidate(encoding(forIANA: metaCharset(sniff)), priority: 340)

        appendCandidate(.utf8, priority: 260)
        appendCandidate(gbkEncoding, priority: 240)
        appendCandidate(cfEncoding(CFStringEncodings.big5), priority: 235)
        appendCandidate(.windowsCP1252, priority: 180)
        appendCandidate(.isoLatin1, priority: 120)

        // Decoded text is memoised by candidate index: the short-circuit pass below
        // and the scoring pass walk overlapping candidate sets, and re-running
        // `String(data:encoding:)` over a multi-hundred-KB body is the single most
        // expensive thing in this file.
        var decodedByIndex = [Int: String]()
        func decoded(_ index: Int) -> String? {
            if let cached = decodedByIndex[index] { return cached }
            guard let text = String(data: data, encoding: candidates[index].encoding) else {
                return nil
            }
            decodedByIndex[index] = text
            return text
        }

        // Short-circuit: if a high-confidence candidate decodes cleanly, take it.
        for index in candidates.indices where candidates[index].priority >= 340 {
            guard let text = decoded(index) else { continue }
            let census = replacementCensus(text)
            let ratio = Double(census.replacements) / Double(max(census.total, 1))
            if ratio < 0.0001 {
                return text
            }
        }

        var best: (text: String, score: Int)?
        for index in candidates.indices {
            guard let text = decoded(index) else { continue }
            let score = candidates[index].priority + decodeQualityScore(text)
            if best == nil || score > best!.score {
                best = (text, score)
            }
        }
        return best?.text
    }

    // MARK: - Charset detection

    static func encoding(forIANA name: String?) -> String.Encoding? {
        guard let n = name?.lowercased().trimmingCharacters(in: .whitespaces), !n.isEmpty else {
            return nil
        }
        switch n {
        case "utf-8", "utf8", "unicode-1-1-utf-8": return .utf8
        case "gbk", "gb2312", "gb_2312", "csgb2312", "x-gbk", "gb18030", "gb-18030", "gb_18030":
            return gbkEncoding
        case "big5", "big5-hkscs", "csbig5", "x-x-big5":
            return cfEncoding(CFStringEncodings.big5)
        case "iso-8859-1", "iso8859-1", "latin1", "iso_8859-1", "csisolatin1":
            return .isoLatin1
        case "windows-1252", "cp1252", "x-cp1252":
            return .windowsCP1252
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji":
            return cfEncoding(CFStringEncodings.shiftJIS)
        case "euc-jp", "x-euc-jp", "cseucpkdfmtjapanese":
            return cfEncoding(CFStringEncodings.EUC_JP)
        case "iso-2022-jp":
            return cfEncoding(CFStringEncodings.ISO_2022_JP)
        case "euc-kr", "x-euc-kr", "cseuckr", "ks_c_5601-1987":
            return cfEncoding(CFStringEncodings.EUC_KR)
        case "windows-1251", "cp1251", "x-cp1251":
            return cfEncoding(CFStringEncodings.windowsCyrillic)
        case "koi8-r", "koi8r":
            return cfEncoding(CFStringEncodings.KOI8_R)
        case "koi8-u":
            return cfEncoding(CFStringEncodings.KOI8_U)
        default:
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            guard cfEnc != kCFStringEncodingInvalidId else { return nil }
            return .init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
        }
    }

    static let gbkEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    static func cfEncoding(_ enc: CFStringEncodings) -> String.Encoding {
        .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(enc.rawValue)))
    }

    private static func bomEncoding(in data: Data) -> String.Encoding? {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return .utf8
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            return .unicode
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            return .utf16LittleEndian
        }
        return nil
    }

    private static func charsetInHeader(_ contentType: String) -> String? {
        let lower = contentType.lowercased()
        guard let r = lower.range(of: "charset=") else { return nil }
        let tail = lower[r.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        let name = tail.components(separatedBy: CharacterSet(charactersIn: " ;,\"'")).first ?? ""
        return name.isEmpty ? nil : name
    }

    /// Pre-compiled charset detection patterns. `NSRegularExpression` matching is
    /// thread-safe, so one shared pair serves every concurrent decode.
    private static let metaCharsetRegexes: [NSRegularExpression] = [
        // <meta … charset="utf-8"> or <meta charset=utf-8>
        try! NSRegularExpression(
            pattern: #"<meta[^>]+charset\s*=\s*["\']?\s*([A-Za-z0-9_\-]+)"#
        ),
        // Fallback: bare charset= anywhere in the sniff window
        try! NSRegularExpression(
            pattern: #"charset\s*=\s*["\']?\s*([A-Za-z0-9_\-]+)"#
        ),
    ]

    private static func metaCharset(_ html: String) -> String? {
        let lower = html.lowercased()
        let nsLower = lower as NSString
        let fullRange = NSRange(location: 0, length: nsLower.length)
        for regex in metaCharsetRegexes {
            guard let match = regex.firstMatch(in: lower, range: fullRange),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: lower)
            else { continue }
            return String(lower[range])
        }
        return nil
    }

    // MARK: - Decode quality scoring

    /// Scoring weights used by `decodeQualityScore`.
    private enum DecodeScoreWeights {
        /// Penalty per U+FFFD replacement character.
        static let replacementChar = 80

        /// Penalty when a known mojibake token appears in the sample.
        /// Tokens such as "锟斤拷" or "â€" only appear when code-pages are mixed.
        static let mojibakeToken = 120

        /// Penalty per unexpected control character (non-whitespace).
        static let controlChar = 25

        /// Cap on the CJK character bonus.
        static let maxCJKBonus = 200

        /// Bonus per recognised HTML structural tag (e.g. <html>, <body>).
        static let htmlTagBonus = 20

        /// Cap on the newline bonus.
        static let maxNewlineBonus = 40

        /// Score returned immediately for an empty sample.
        static let emptyStringSentinel = -10_000

        /// Number of leading characters sampled from the document.
        static let sampleSize = 4096
    }

    /// Replacement-character census over the whole document, in ONE scalar walk.
    /// The previous form (`filter { … }.count` plus a separate `.count`) walked the
    /// document twice and allocated an intermediate array, per candidate encoding.
    private static func replacementCensus(_ text: String) -> (replacements: Int, total: Int) {
        var replacements = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar.value == 0xFFFD { replacements += 1 }
        }
        return (replacements, total)
    }

    private static func decodeQualityScore(_ text: String) -> Int {
        let sample = text.count > DecodeScoreWeights.sampleSize
            ? String(text.prefix(DecodeScoreWeights.sampleSize))
            : text
        if sample.isEmpty { return DecodeScoreWeights.emptyStringSentinel }

        var score = 0

        let replacementCount = sample.unicodeScalars.filter { $0.value == 0xFFFD }.count
        score -= replacementCount * DecodeScoreWeights.replacementChar

        let suspiciousTokens = ["锟斤拷", "Ã", "Â", "â€", "â€œ", "â€\u{201D}", "ï»¿", "\u{FFFD}"]
        for token in suspiciousTokens {
            score -= sample.components(separatedBy: token).count > 1 ? DecodeScoreWeights.mojibakeToken : 0
        }

        let controlCount = sample.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }.count
        score -= controlCount * DecodeScoreWeights.controlChar

        let cjkCount = sample.unicodeScalars.filter {
            switch $0.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF: return true
            default: return false
            }
        }.count
        score += min(cjkCount, DecodeScoreWeights.maxCJKBonus)

        let htmlHints = ["<html", "<body", "</html>", "<meta", "<title"]
        for hint in htmlHints where sample.localizedCaseInsensitiveContains(hint) {
            score += DecodeScoreWeights.htmlTagBonus
        }

        let newlineCount = sample.filter { $0 == "\n" }.count
        score += min(newlineCount, DecodeScoreWeights.maxNewlineBonus)

        return score
    }
}
