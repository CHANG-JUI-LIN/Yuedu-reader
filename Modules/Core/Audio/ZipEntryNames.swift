import Foundation
import ReadiumZIPFoundation

/// A zip's entry names decoded as the archive was written.
///
/// The ZIP format only marks UTF-8 names (general-purpose bit 11) and calls every other
/// name code page 437, which is what `Entry.path` decodes it as. Most archives that leave the
/// flag off are not CP437: macOS `zip` writes UTF-8 without the flag, and Windows writes the
/// system code page — GBK, Big5, Shift_JIS — so a Chinese chapter list arrived as
/// 「01 τ¼¼1τ½á」.
///
/// A name that is valid UTF-8 is UTF-8, flag or not (legacy CJK bytes are practically never
/// valid UTF-8). The rest of the archive's names share one legacy code page, chosen by
/// Foundation's detector over all of them together, with no language hint: measured on
/// 2026-11-11, a hint made a lone GBK or Big5 name read as Shift_JIS, and EUC-KR as GBK.
/// Names that no CJK code page decodes stay CP437, as the format says.
enum ZipEntryNames {
    /// Each entry with its decoded path, in the archive's order.
    static func decode(_ entries: [Entry], archiveName: String) -> [(entry: Entry, path: String)] {
        let decoded = decode(rawNames: entries.map(rawName))
        if let legacy = decoded.legacyEncoding {
            AppLogger.parse(
                "Zip entry names are not UTF-8; decoded with a legacy code page",
                context: ["archive": archiveName, "encoding": String.localizedName(of: legacy)],
                level: .info
            )
        }
        return Array(zip(entries, decoded.names))
    }

    /// The decoding itself, over each name's bytes as stored.
    static func decode(rawNames: [Data]) -> (names: [String], legacyEncoding: String.Encoding?) {
        let legacyNames = rawNames.filter { String(data: $0, encoding: .utf8) == nil }
        guard !legacyNames.isEmpty else {
            return (rawNames.map { String(decoding: $0, as: UTF8.self) }, nil)
        }
        let legacy = legacyEncoding(of: legacyNames)
        let names = rawNames.map { raw in
            String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: legacy)
                // The detector accepted every one of these names together, so a detected
                // code page does not reject one here; CP437 maps all 256 bytes regardless.
                ?? String(data: raw, encoding: codePage437) ?? ""
        }
        return (names, legacy)
    }

    static let codePage437 = encoding(.dosLatinUS)

    private static let candidateEncodings: [String.Encoding] = [
        encoding(.GB_18030_2000), encoding(.big5_HKSCS_1999), .shiftJIS, encoding(.EUC_KR),
    ]

    private static func legacyEncoding(of names: [Data]) -> String.Encoding {
        let joined = names.reduce(into: Data()) { result, name in
            result.append(name)
            result.append(0x0A)
        }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let detected = NSString.stringEncoding(
            for: joined,
            encodingOptions: [
                .suggestedEncodingsKey: candidateEncodings.map(\.rawValue),
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        // The detector can name an encoding without converting anything (seen 2026-11-11:
        // EUC-KR for a CP437 「Café」, with no converted string), so a code page counts only
        // when it decodes every one of the names.
        let encoding = String.Encoding(rawValue: detected)
        guard detected != 0, converted != nil, !lossy.boolValue,
              names.allSatisfy({ String(data: $0, encoding: encoding) != nil })
        else { return codePage437 }
        return encoding
    }

    /// The name's bytes as stored: ISO Latin-1 maps every byte to one character and back.
    private static func rawName(_ entry: Entry) -> Data {
        Data(entry.path(using: .isoLatin1).unicodeScalars.map { UInt8($0.value) })
    }

    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }
}
