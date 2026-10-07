import Foundation

/// OPDS 2.0 (JSON) documents, mapped onto the same `OPDSFeed` / `OPDSEntry`
/// models the Atom parser produces. `OPDSClient.parseFeed` chooses the parser
/// by Content-Type; there is no second browser or loader.
///
/// The models are flat, so groups are flattened: a group's navigation links
/// become navigation entries; a publications group with a `self` link becomes
/// one navigation entry to that link (its "see all" page); a publications group
/// without one contributes its publications inline, so nothing is dropped.
enum OPDS2FeedParser {
    /// Gutenberg's OPDS 2 development endpoint answers `application/json`
    /// rather than `application/opds+json`, so plain JSON is accepted too.
    private static let mediaTypes: Set<String> = [
        "application/opds+json", "application/opds-publication+json", "application/json",
    ]

    static func handles(contentType: String?) -> Bool {
        guard let mime = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return mediaTypes.contains(mime)
    }

    static func parse(data: Data, feedURL: URL) throws -> OPDSFeed {
        guard !data.isEmpty else { throw OPDSError.noData }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch {
            AppLogger.parse("OPDS 2 document could not be decoded", error: error, context: ["url": feedURL.absoluteString])
            throw OPDSError.invalidFeed
        }
        return try Mapper(base: feedURL).feed(from: document)
    }

    /// Converts the RFC 6570 search template OPDS 2 uses (for example
    /// `search{?query,title,author}`) into the OpenSearch form that
    /// `OPDSClient.resolveSearchTemplate` already expands and encodes. Only
    /// `query` is filled; the other variables are undefined, and RFC 6570
    /// omits undefined variables. Returns nil when the template has no `query`.
    static func openSearchTemplate(fromURITemplate template: String) -> String? {
        var result = ""
        var rest = template[...]
        var hasQuery = false
        while let match = rest.firstMatch(of: #/\{([?&]?)([^{}]*)\}/#) {
            result += rest[..<match.range.lowerBound]
            let names = match.output.2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if names.contains("query") {
                hasQuery = true
                switch match.output.1 {
                case "?": result += "?query={searchTerms}"
                case "&": result += "&query={searchTerms}"
                default: result += "{searchTerms}"
                }
            }
            rest = rest[match.range.upperBound...]
        }
        result += rest
        return hasQuery ? result : nil
    }
}

// MARK: - Mapping

private struct Mapper {
    let base: URL
    var feedAlternateURL: URL?

    func feed(from document: OPDS2FeedParser.Document) throws -> OPDSFeed {
        var feed = OPDSFeed()
        feed.title = Self.plain(document.metadata?.title?.value ?? "", limit: 512)
        for link in document.links ?? [] { applyFeedLink(link, to: &feed) }
        // Books inherit the feed's web page, as in the Atom parser.
        let mapper = Mapper(base: base, feedAlternateURL: feed.alternateURL)

        // A feed has at least one collection; a publication document has none.
        if document.navigation == nil, document.publications == nil, document.groups == nil {
            guard let metadata = document.metadata else {
                AppLogger.parse("OPDS 2 document has neither collections nor publication metadata", context: ["url": base.absoluteString])
                throw OPDSError.invalidFeed
            }
            let publication = OPDS2FeedParser.Publication(metadata: metadata, links: document.links, images: document.images)
            if let entry = mapper.entry(for: publication) { feed.entries.append(entry) }
            return feed
        }

        feed.entries += (document.navigation ?? []).compactMap { mapper.navigationEntry($0) }
        for group in document.groups ?? [] { feed.entries += mapper.entries(for: group) }
        feed.entries += (document.publications ?? []).compactMap { mapper.entry(for: $0) }
        return feed
    }

    private func applyFeedLink(_ link: OPDS2FeedParser.Link, to feed: inout OPDSFeed) {
        let rels = link.rels
        if rels.contains("search") {
            if link.templated == true || link.href.contains("{") {
                if let template = OPDS2FeedParser.openSearchTemplate(fromURITemplate: link.href) {
                    feed.search = .template(template, baseURL: base)
                }
            } else if let url = resolve(link.href) {
                feed.searchDescriptionURL = url
                feed.search = .description(url)
            }
            return
        }
        guard link.templated != true, let url = resolve(link.href) else { return }
        if rels.contains("next") { feed.nextPageURL = url }
        else if rels.contains("alternate"), link.mime == "text/html" { feed.alternateURL = url }
    }

    private func entries(for group: OPDS2FeedParser.Group) -> [OPDSEntry] {
        var entries = (group.navigation ?? []).compactMap { navigationEntry($0) }
        guard let publications = group.publications else { return entries }
        let title = group.metadata?.title?.value ?? ""
        if let all = group.links?.first(where: { $0.rels.contains("self") && $0.templated != true }),
           let url = resolve(all.href) {
            let name = Self.plain(title.isEmpty ? (all.title ?? "") : title, limit: 512)
            entries.append(OPDSEntry(id: url.absoluteString, title: name.isEmpty ? url.absoluteString : name, navigationURL: url))
        } else {
            entries += publications.compactMap { entry(for: $0) }
        }
        return entries
    }

    private func navigationEntry(_ link: OPDS2FeedParser.Link) -> OPDSEntry? {
        guard link.templated != true, let url = resolve(link.href) else { return nil }
        let title = Self.plain(link.title ?? "", limit: 512)
        return OPDSEntry(id: url.absoluteString, title: title.isEmpty ? url.absoluteString : title, navigationURL: url)
    }

    private func entry(for publication: OPDS2FeedParser.Publication) -> OPDSEntry? {
        let metadata = publication.metadata
        var entry = OPDSEntry(id: "", title: Self.plain(metadata.title?.value ?? "", limit: 512))
        for link in publication.links ?? [] where link.templated != true {
            let rels = link.rels
            if rels.contains(where: { $0.hasSuffix("/image/thumbnail") }) || rels.contains(where: { $0.hasSuffix("/image") }) {
                applyImage(link, thumbnail: rels.contains { $0.hasSuffix("/image/thumbnail") }, to: &entry)
                continue
            }
            guard let url = resolve(link.href) else { continue }
            if let rel = rels.first(where: Self.isAcquisition) {
                entry.acquisitions.append(OPDSAcquisition(url: url, type: link.type ?? "", rel: rel))
            } else if rels.contains("alternate"), link.mime == "text/html" {
                entry.alternateURL = url
            } else if entry.navigationURL == nil,
                      rels.contains("self") || rels.contains("subsection") || link.mime.hasPrefix("application/opds") {
                entry.navigationURL = url
            }
        }
        applyImages(publication.images ?? [], to: &entry)

        let authors = metadata.author.filter { !$0.name.isEmpty }
        entry.authorNames = authors.map { Self.plain($0.name, limit: 256) }
        entry.author = entry.authorNames.isEmpty ? nil : entry.authorNames.joined(separator: ", ")
        for author in authors {
            for link in author.links where link.templated != true && link.mime.hasPrefix("application/opds") {
                if let url = resolve(link.href) {
                    entry.relatedLinks.append(OPDSRelatedLink(title: Self.plain(link.title ?? author.name, limit: 512), url: url))
                }
            }
        }
        if let description = metadata.description, !description.isEmpty {
            entry.summary = Self.plain(description, limit: 8_000)
        }
        guard entry.isBook || entry.isNavigation else { return nil }
        if entry.alternateURL == nil, entry.isBook { entry.alternateURL = feedAlternateURL }
        entry.id = metadata.identifier ?? entry.navigationURL?.absoluteString
            ?? entry.acquisitions.first?.url.absoluteString ?? ""
        return entry
    }

    /// `images` has no rels; the largest is the cover and, when the publication
    /// lists more than one with sizes, the smallest is the thumbnail.
    private func applyImages(_ images: [OPDS2FeedParser.Link], to entry: inout OPDSEntry) {
        guard !images.isEmpty else { return }
        let sized = images.filter { $0.width != nil }
        let cover = sized.max { $0.width! < $1.width! } ?? images[0]
        applyImage(cover, thumbnail: false, to: &entry)
        if sized.count > 1, let small = sized.min(by: { $0.width! < $1.width! }), small.href != cover.href {
            applyImage(small, thumbnail: true, to: &entry)
        }
    }

    private func applyImage(_ link: OPDS2FeedParser.Link, thumbnail: Bool, to entry: inout OPDSEntry) {
        // Inline raster images are image data, never a navigation URL (as in Atom).
        let url: URL?
        if link.href.hasPrefix("data:image/") {
            url = link.href.utf8.count <= 2 * 1024 * 1024 ? URL(string: link.href) : nil
        } else {
            url = resolve(link.href)
        }
        guard let url else { return }
        if thumbnail { entry.thumbnailURL = url } else if entry.coverURL == nil { entry.coverURL = url }
    }

    private func resolve(_ href: String) -> URL? {
        guard !href.isEmpty, let resolved = URL(string: href, relativeTo: base)?.absoluteURL else { return nil }
        return OPDSClient.url(from: resolved.absoluteString)
    }

    private static func isAcquisition(_ rel: String) -> Bool {
        rel.hasPrefix("http://opds-spec.org/acquisition") || rel.hasPrefix("https://opds-spec.org/acquisition")
    }

    private static func plain(_ value: String, limit: Int) -> String { OPDSClient.plainMetadata(value, limit: limit) }
}

// MARK: - Document model
//
// Only the members the mapping reads are declared; Decodable ignores every
// other key, so unknown and extension fields never fail a document. Wrong
// types in declared members do fail it.

extension OPDS2FeedParser {
    struct Document: Decodable {
        var metadata: Metadata?
        var links: [Link]?
        var navigation: [Link]?
        var publications: [Publication]?
        var groups: [Group]?
        var images: [Link]?
    }

    struct Group: Decodable {
        var metadata: Metadata?
        var links: [Link]?
        var navigation: [Link]?
        var publications: [Publication]?
    }

    struct Publication: Decodable {
        var metadata: Metadata
        var links: [Link]?
        var images: [Link]?
    }

    struct Metadata: Decodable {
        var identifier: String?
        var title: LocalizedString?
        var description: String?
        var language: [String] = []
        var author: [Contributor] = []

        private enum CodingKeys: String, CodingKey { case identifier, title, description, language, author }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
            title = try values.decodeIfPresent(LocalizedString.self, forKey: .title)
            description = try values.decodeIfPresent(String.self, forKey: .description)
            language = try values.decodeIfPresent(OneOrMany<String>.self, forKey: .language)?.values ?? []
            author = try values.decodeIfPresent(OneOrMany<Contributor>.self, forKey: .author)?.values ?? []
        }
    }

    struct Link: Decodable {
        var href: String
        var type: String?
        var title: String?
        var templated: Bool?
        var width: Int?
        var rels: [String] = []

        private enum CodingKeys: String, CodingKey { case href, type, title, templated, width, rel }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            href = try values.decode(String.self, forKey: .href)
            type = try values.decodeIfPresent(String.self, forKey: .type)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            templated = try values.decodeIfPresent(Bool.self, forKey: .templated)
            width = try values.decodeIfPresent(Int.self, forKey: .width)
            rels = (try values.decodeIfPresent(OneOrMany<String>.self, forKey: .rel)?.values ?? []).map { $0.lowercased() }
        }

        var mime: String {
            (type ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        }
    }

    /// A contributor is a bare name or an object with `name` and optional
    /// `sortAs`, `identifier` and `links`.
    struct Contributor: Decodable {
        var name: String
        var sortAs: String?
        var links: [Link] = []

        private enum CodingKeys: String, CodingKey { case name, sortAs, links }

        init(from decoder: Decoder) throws {
            do {
                name = try decoder.singleValueContainer().decode(String.self)
            } catch DecodingError.typeMismatch {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                name = try values.decode(LocalizedString.self, forKey: .name).value
                sortAs = try values.decodeIfPresent(String.self, forKey: .sortAs)
                links = try values.decodeIfPresent([Link].self, forKey: .links) ?? []
            }
        }
    }

    /// A string or a language map (`{"en": "…", "fr": "…"}`).
    struct LocalizedString: Decodable {
        var value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            do { value = try container.decode(String.self) }
            catch DecodingError.typeMismatch {
                value = Self.pick(try container.decode([String: String].self))
            }
        }

        /// The reader's preferred language, then English, then the first key in
        /// sorted order, so the choice is deterministic.
        static func pick(_ map: [String: String], preferred: [String] = Locale.preferredLanguages) -> String {
            let byLanguage = Dictionary(map.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            for language in preferred.map({ $0.lowercased() }) + ["en"] {
                if let exact = byLanguage[language] { return exact }
                let primary = language.split(separator: "-").first.map(String.init) ?? language
                if let match = byLanguage[primary] { return match }
            }
            return byLanguage.keys.sorted().first.flatMap { byLanguage[$0] } ?? ""
        }
    }

    /// OPDS 2 allows a single value wherever an array is allowed.
    struct OneOrMany<Element: Decodable>: Decodable {
        var values: [Element]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            do { values = try container.decode([Element].self) }
            catch DecodingError.typeMismatch { values = [try container.decode(Element.self)] }
        }
    }
}
