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
    static func decode(data: Data, response: URLResponse?) -> String? {
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
        // UTF-8 is self-validating: multi-byte sequences have a rigid bit pattern that other
        // encodings' output almost never satisfies by accident across a whole document. So bytes
        // that validate as UTF-8 *and* actually use multi-byte sequences outrank a declared
        // charset — servers mislabel UTF-8 pages as ISO-8859-1 constantly (a default in stock
        // Apache/nginx configs), and honouring that label renders every Chinese chapter as
        // `è ± å° å®¶` while the ASCII markup around it still looks fine.
        if usesMultiByteUTF8(data) {
            appendCandidate(.utf8, priority: 400)
        }
        appendCandidate(encoding(forIANA: response?.textEncodingName), priority: 380)

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
            // A charset the response declares (BOM, header, meta — what Legado decodes with)
            // is read as Java's `String(bytes, charset)` reads it: bytes it cannot map become
            // U+FFFD and the page stays. Strict decoding dropped a declared UTF-8 page over one
            // bad byte (新御书屋's book pages, `charset=UTF-8` in header and meta): every UTF-8
            // candidate failed, cp1252 won, and `text.显示全部章节` matched nothing in the
            // mojibake. The replacements count against the candidate below, so a wrong
            // declaration still loses; the undeclared guesses stay strict.
            let encoding = candidates[index].encoding
            let declared = candidates[index].priority >= 340
            guard let text = String(data: data, encoding: encoding)
                    ?? (declared ? lossyDecode(data, encoding) : nil) else {
                return nil
            }
            decodedByIndex[index] = text
            return text
        }

        // Short-circuit: if a high-confidence candidate decodes cleanly, take it.
        //
        // "Decodes cleanly" only means something for an encoding that can *fail*. A single-byte
        // encoding maps all 256 byte values to characters, so it never emits U+FFFD no matter what
        // it is fed — accepting one here on a zero-replacement result is how a mislabeled UTF-8
        // page short-circuited into mojibake before the document's own `<meta charset>` (a lower
        // priority candidate) ever got a turn. Those encodings go to the scoring pass instead.
        for index in candidates.indices where candidates[index].priority >= 340 {
            guard !acceptsAnyByteSequence(candidates[index].encoding) else { continue }
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

    /// Decodes a source's response; `declaredCharset` is the source's `charset` URL option.
    ///
    /// Legado decodes a response without that option — it encodes the request alone:
    /// `newCallStrResponse` reads `body.text()` (legado-E, MD3 and upstream agree), which takes
    /// the Content-Type charset, then the page's `<meta>` (`EncodingDetect.getHtmlEncode`), then
    /// ICU's `CharsetDetector`. So a page that declares its charset — BOM, header or `<meta>` —
    /// or is plainly UTF-8 decodes as it declares (`decode(data:response:)`): 福书网吧
    /// (YCK1331) posts its search as `gbk` and gets back a page declaring UTF-8, which the option
    /// had turned into "淇℃伅鎻愮ず" instead of 信息提示.
    ///
    /// A page that declares nothing is left to ICU's detection in Legado, which tells Big5 from
    /// GBK where `decode(data:response:)` does not (`RuntimeFetchDecodingTests`). There the
    /// option stands in for that detector — the source's author named the charset the site
    /// sends — and, as with Java's decoder, bytes it cannot map become U+FFFD. Delete this
    /// branch if detection here ever reads undeclared Big5 correctly.
    static func decode(data: Data, response: URLResponse?, declaredCharset: String?) -> String? {
        let name = declaredCharset?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, !pageDeclaresCharset(data: data, response: response) else {
            return decode(data: data, response: response)
        }
        guard let declared = encoding(forIANA: name) else {
            AppLogger.parse("unknown charset option; detecting the page's charset", context: ["charset": name])
            return decode(data: data, response: response)
        }
        return String(data: data, encoding: declared) ?? lossyDecode(data, declared)
    }

    /// What Legado's `body.text()` decodes by before it guesses: a BOM, the Content-Type charset,
    /// or the page's `<meta>` — or bytes ICU would read as UTF-8 at once (valid, multi-byte).
    private static func pageDeclaresCharset(data: Data, response: URLResponse?) -> Bool {
        if bomEncoding(in: data) != nil || usesMultiByteUTF8(data) { return true }
        if encoding(forIANA: response?.textEncodingName) != nil { return true }
        if let http = response as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           encoding(forIANA: charsetInHeader(contentType)) != nil {
            return true
        }
        let sniff = String(data: data.prefix(DecodeScoreWeights.sampleSize), encoding: .isoLatin1) ?? ""
        return encoding(forIANA: metaCharset(sniff)) != nil
    }

    /// `data` in `encoding` with every byte sequence it cannot map replaced by U+FFFD, as
    /// Java's `String(bytes, charset)` does.
    private static func lossyDecode(_ data: Data, _ encoding: String.Encoding) -> String? {
        if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }
        var converted: NSString?
        var usedLossyConversion: ObjCBool = false
        _ = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [encoding.rawValue],
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: true,
                .lossySubstitutionKey: "\u{FFFD}",
            ],
            convertedString: &converted,
            usedLossyConversion: &usedLossyConversion
        )
        return converted as String?
    }

    /// True when `data` is valid UTF-8 **and** actually contains a multi-byte sequence.
    /// Pure ASCII is excluded on purpose: it decodes identically under every candidate here, so it
    /// carries no evidence about which one the server meant.
    private static func usesMultiByteUTF8(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard data.contains(where: { $0 >= 0x80 }) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// Encodings that decode any byte sequence without ever producing U+FFFD, so a clean decode
    /// from them is not evidence of anything.
    private static func acceptsAnyByteSequence(_ encoding: String.Encoding) -> Bool {
        switch encoding {
        case .isoLatin1, .isoLatin2, .windowsCP1250, .windowsCP1251, .windowsCP1252,
             .windowsCP1253, .windowsCP1254, .macOSRoman:
            return true
        default:
            return false
        }
    }

    // MARK: - Charset detection

    static func encoding(forIANA name: String?) -> String.Encoding? {
        guard let n = name?.lowercased().trimmingCharacters(in: .whitespaces), !n.isEmpty else {
            return nil
        }
        switch n {
        // Java's own names too (`UTF8`, `ISO8859_1`): sources pass them to `java.*` calls.
        case "utf-8", "utf8", "utf_8", "unicode-1-1-utf-8": return .utf8
        case "gbk", "gb2312", "gb_2312", "csgb2312", "x-gbk", "gb18030", "gb-18030", "gb_18030":
            return gbkEncoding
        case "big5", "big5-hkscs", "csbig5", "x-x-big5":
            return cfEncoding(CFStringEncodings.big5)
        case "iso-8859-1", "iso8859-1", "latin1", "iso_8859-1", "csisolatin1", "iso8859_1", "iso_8859_1", "8859_1":
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

    /// The `charset=` parameter of a `Content-Type` value, lowercased.
    static func charsetInHeader(_ contentType: String) -> String? {
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
