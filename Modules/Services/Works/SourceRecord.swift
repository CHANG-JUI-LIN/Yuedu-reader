import Foundation

// Unified library, Phase 1a: the identity of a book wherever it comes from — a copy on the
// shelf, a remote library entry, a book source result, a public library work. Design
// `Technotes/UnifiedLibrary-2026-10-08-design.md` §4–§6. All value types, so they can be
// frozen into routes (audit §11.5).

/// The design's "Provider Type": what kind of place a book comes from.
enum ProviderType: String, Codable, Hashable, Sendable {
    /// The shelf and reading records on this device.
    case library
    /// Remote libraries, as `RemoteLibraryKind`.
    case opds, webDAV, calibre
    /// Built-in public libraries.
    case gutenberg, aozora
    /// Legado book sources (來源配置).
    case bookSource
    /// Bibliographic databases (Open Library…), later phases.
    case bibliographic
    /// Installed rule modules (Phase 6d), by `RuleModule.id`.
    case module
}

/// One place of a kind: a remote connection, a book source, a public library.
struct SourceInstanceKey: Hashable, Codable, Sendable {
    var type: ProviderType
    /// library: "local"; opds/webDAV/calibre: the connection id; gutenberg/aozora: the
    /// `PublicLibraryID`; bookSource: its `bookSourceUrl` (portable, unlike its device-local
    /// UUID — design D4), or "missing:<uuid>" when the source is gone.
    var id: String

    static let localLibrary = SourceInstanceKey(type: .library, id: "local")
}

/// One item within a place. Decisions (design D3) refer only to this key.
struct SourceItemKey: Hashable, Codable, Sendable {
    var instance: SourceInstanceKey
    /// library: `ReadingBook.id`; OPDS/Calibre: the entry id; WebDAV: the path below the
    /// connection's root; bookSource: the normalized detail URL; aozora: the work id;
    /// gutenberg: the ebook number.
    var item: String

    /// A copy's own key. `ReadingBook.id` syncs with the book, so this key is portable, and
    /// it does not change when the copy changes source (Phase 1 plan, decision 4).
    static func copy(_ id: UUID) -> SourceItemKey {
        SourceItemKey(instance: .localLibrary, item: id.uuidString.lowercased())
    }
}

/// An identifier shared across places. Only equal schemes are compared.
struct ExternalIdentifier: Hashable, Codable, Sendable {
    enum Scheme: String, Codable, Hashable, Sendable {
        case isbn13
        case calibreUUID
        case gutenberg
        case aozoraWork
        case openLibraryWork
        case openLibraryEdition
        case wikidata
        /// An OPF `dc:identifier` that is not an ISBN; compared only within this scheme.
        case epubUniqueIdentifier
    }

    let scheme: Scheme
    let value: String

    private init(verifiedScheme scheme: Scheme, value: String) {
        self.scheme = scheme
        self.value = value
    }

    /// Nil when `raw` is not a valid value of `scheme`. ISBN-10s become ISBN-13s and check
    /// digits are verified; uuids lose `urn:uuid:` and are lowercased; Gutenberg numbers are
    /// taken as they are, or read from `urn:gutenberg:N[:edition]` or a `…/ebooks/N` URL.
    static func normalized(_ scheme: Scheme, _ raw: String) -> ExternalIdentifier? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch scheme {
        case .isbn13:
            return isbn13(from: trimmed).map { ExternalIdentifier(verifiedScheme: .isbn13, value: $0) }
        case .calibreUUID:
            var value = trimmed.lowercased()
            if value.hasPrefix("urn:uuid:") { value.removeFirst("urn:uuid:".count) }
            guard UUID(uuidString: value) != nil else { return nil }
            return ExternalIdentifier(verifiedScheme: .calibreUUID, value: value)
        case .gutenberg:
            let number = trimmed.allSatisfy(\.isASCII) && trimmed.allSatisfy(\.isNumber) ? trimmed : gutenbergNumber(from: trimmed)
            return number.map { ExternalIdentifier(verifiedScheme: .gutenberg, value: $0) }
        case .aozoraWork, .openLibraryWork, .openLibraryEdition, .wikidata, .epubUniqueIdentifier:
            return ExternalIdentifier(verifiedScheme: scheme, value: trimmed)
        }
    }

    /// The ebook number in `urn:gutenberg:N[:edition]`, `…/ebooks/N` or `…/ebooks/N.opds`.
    static func gutenbergNumber(from raw: String) -> String? {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("urn:gutenberg:") {
            let number = lowered.dropFirst("urn:gutenberg:".count).prefix { $0.isNumber }
            return number.isEmpty ? nil : String(number)
        }
        guard let url = URL(string: raw), let host = url.host, host.hasSuffix("gutenberg.org") else { return nil }
        let components = url.pathComponents
        guard let index = components.lastIndex(of: "ebooks"), index + 1 < components.count else { return nil }
        let name = (components[index + 1] as NSString).deletingPathExtension
        return !name.isEmpty && name.allSatisfy(\.isNumber) ? name : nil
    }

    private static func isbn13(from raw: String) -> String? {
        // `urn:isbn:` and hyphens drop out here; only digits and a final X remain.
        let digits = raw.uppercased().filter { ($0.isASCII && $0.isNumber) || $0 == "X" }
        if digits.count == 10 {
            let body = Array(digits)
            guard body.dropLast().allSatisfy(\.isNumber) else { return nil }
            let sum = body.enumerated().reduce(0) { total, pair in
                let value = pair.element == "X" ? 10 : Int(String(pair.element)) ?? -100
                return total + value * (10 - pair.offset)
            }
            guard sum % 11 == 0 else { return nil }
            let stem = "978" + String(body.dropLast())
            return stem + String(isbn13CheckDigit(stem))
        }
        guard digits.count == 13, digits.allSatisfy(\.isNumber),
              digits.hasPrefix("978") || digits.hasPrefix("979") else { return nil }
        let stem = String(digits.prefix(12))
        return isbn13CheckDigit(stem) == Int(String(digits.last!)) ? digits : nil
    }

    private static func isbn13CheckDigit(_ stem: String) -> Int {
        let sum = stem.enumerated().reduce(0) { total, pair in
            total + (Int(String(pair.element)) ?? 0) * (pair.offset.isMultiple(of: 2) ? 1 : 3)
        }
        return (10 - sum % 10) % 10
    }
}

enum ContentKind: String, Codable, Hashable, Sendable {
    case text, comic, audio
}

/// How a record can be read; the existing services still perform it (design D7).
enum AcquisitionOption: Hashable, Codable, Sendable {
    case openCopy(UUID)
    case readRemote(format: String)
    case download(format: String)
    case readOnline
    case viewOnly
}

/// What one place says about one item.
struct SourceRecord: Hashable, Codable, Sendable {
    var key: SourceItemKey
    var title: String
    var authors: [String]
    var language: String?
    var contentKind: ContentKind
    var identifiers: Set<ExternalIdentifier>
    /// Set when the record describes a copy on this device.
    var copyID: UUID?
    var acquisitions: [AcquisitionOption]

    /// The copy's own key, when the record describes a copy (decision 4).
    var copyKey: SourceItemKey? { copyID.map(SourceItemKey.copy) }
}
