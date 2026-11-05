import CryptoKit
import Foundation

/// One TXT chapter rule, in legado's `TxtTocRule` shape so a legado `txtRule` export imports
/// as is: `rule` (upstream, legado-E) and `chapterRule` (legado-with-MD3) are the same field,
/// `volumeRule` is MD3's, and other keys (legado-E's `replacement`) are ignored.
struct TXTTocRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: Int64
    var name: String
    var chapterRule: String
    /// Lines a volume heading takes: kept as chapters only when a chapter heading follows
    /// them with nothing but whitespace between (第一卷 → 第1章), so a list of volumes
    /// inside a chapter's text stays text. Empty for none.
    var volumeRule: String
    var example: String?
    var serialNumber: Int
    var enable: Bool

    init(id: Int64, name: String, chapterRule: String, volumeRule: String = "",
         example: String? = nil, serialNumber: Int = -1, enable: Bool = true) {
        self.id = id
        self.name = name
        self.chapterRule = chapterRule
        self.volumeRule = volumeRule
        self.example = example
        self.serialNumber = serialNumber
        self.enable = enable
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, chapterRule, rule, volumeRule, example, serialNumber, enable
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // legado writes ids as numbers; hand-edited files sometimes quote them.
        if let number = try? container.decode(Int64.self, forKey: .id) {
            id = number
        } else if let text = try container.decodeIfPresent(String.self, forKey: .id), let number = Int64(text) {
            id = number
        } else {
            id = Self.newID()
        }
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        chapterRule = try container.decodeIfPresent(String.self, forKey: .chapterRule)
            ?? container.decodeIfPresent(String.self, forKey: .rule) ?? ""
        volumeRule = try container.decodeIfPresent(String.self, forKey: .volumeRule) ?? ""
        example = try container.decodeIfPresent(String.self, forKey: .example)
        serialNumber = try container.decodeIfPresent(Int.self, forKey: .serialNumber) ?? -1
        enable = try container.decodeIfPresent(Bool.self, forKey: .enable) ?? true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        // Both spellings, so upstream legado (`rule`) and MD3 (`chapterRule`) read an export.
        try container.encode(chapterRule, forKey: .rule)
        try container.encode(chapterRule, forKey: .chapterRule)
        try container.encode(volumeRule, forKey: .volumeRule)
        try container.encodeIfPresent(example, forKey: .example)
        try container.encode(serialNumber, forKey: .serialNumber)
        try container.encode(enable, forKey: .enable)
    }

    /// Milliseconds, as legado's `System.currentTimeMillis()` ids.
    static func newID() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}

/// Why a rule cannot be saved or used.
enum TXTTocRuleError: Error, Equatable {
    case emptyChapterRule
    case invalidRegex(field: Field, message: String)

    enum Field: Equatable { case chapter, volume }
}

extension TXTTocRule {
    /// The regex options every rule runs with: legado compiles with MULTILINE; each title
    /// candidate is one line, matched with its preceding line break as context.
    static let regexOptions: NSRegularExpression.Options = [.anchorsMatchLines]

    /// Compiles one pattern the way the parser will run it (Java syntax through
    /// `RegexSanitizer`), naming the field that failed.
    static func compile(_ pattern: String, field: TXTTocRuleError.Field) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: RegexSanitizer.sanitize(pattern), options: regexOptions)
        } catch {
            throw TXTTocRuleError.invalidRegex(field: field, message: error.localizedDescription)
        }
    }

    /// The rule ready to run, or why it cannot.
    func compiled() throws -> TXTCompiledTocRule {
        let chapter = chapterRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chapter.isEmpty else { throw TXTTocRuleError.emptyChapterRule }
        let volume = volumeRule.trimmingCharacters(in: .whitespacesAndNewlines)
        return TXTCompiledTocRule(
            id: id,
            chapter: try Self.compile(chapterRule, field: .chapter),
            volume: volume.isEmpty ? nil : try Self.compile(volumeRule, field: .volume),
            titleStarts: TXTTocRuleDefaults.titleStarts(for: self)
        )
    }
}

struct TXTCompiledTocRule: @unchecked Sendable {
    // NSRegularExpression is immutable and documented thread-safe.
    let id: Int64
    let chapter: NSRegularExpression
    let volume: NSRegularExpression?
    /// The characters a built-in rule's headings can start with (after leading whitespace),
    /// for the byte prefilter; nil for any other rule, which turns the prefilter off.
    let titleStarts: [String]?
}

/// The enabled rules in list order, compiled once, with the fingerprint a chapter index
/// built from them is cached under. A rule that no longer compiles is skipped and logged.
struct TXTTocRuleSet: Sendable {
    let rules: [TXTCompiledTocRule]
    let fingerprint: String

    /// Bump when the parser's use of the same rules changes what it produces.
    static let parserGeneration = 1

    init(rules source: [TXTTocRule]) {
        var compiled: [TXTCompiledTocRule] = []
        var hasher = SHA256()
        hasher.update(data: Data("generation=\(Self.parserGeneration)\n".utf8))
        for rule in source where rule.enable {
            do {
                compiled.append(try rule.compiled())
                hasher.update(data: Data("\(rule.chapterRule)\u{1F}\(rule.volumeRule)\u{1E}".utf8))
            } catch {
                AppLogger.error("TXT chapter rule skipped", error: error,
                                context: ["id": rule.id, "name": rule.name])
            }
        }
        rules = compiled
        fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
