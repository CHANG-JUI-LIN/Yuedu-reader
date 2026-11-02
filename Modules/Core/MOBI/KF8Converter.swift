// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation
import SwiftSoup

/// KF8 → EPUB content (foliate's `KF8` class). A KF8 file keeps its source's
/// XHTML, cut into skeletons with fragments inserted into them; its stylesheets
/// and SVG as further flows of the text; and its pictures and fonts as resource
/// records, all named by `kindle:` URLs. The conversion puts each file back
/// together and turns those URLs into package paths.
///
/// The markup is edited as bytes and text, never re-serialised: a chapter holds
/// what the file holds, `aid` attributes included, apart from the URLs and the
/// `id`s that link targets need.
enum KF8Converter {
    private struct Fragment {
        /// Where the fragment starts in its assembled section, plus the
        /// skeleton's offset in the text: the index entry's name.
        var insertOffset: Int
        /// The number `kindle:pos` links and the NCX name the fragment by.
        var id: Int
        /// Where the fragment's bytes start, counted from the end of its skeleton's.
        var offset: Int
        var length: Int
    }

    private struct Section {
        /// Where the skeleton starts in the text; its fragments follow it.
        var offset: Int
        var skeletonLength: Int
        var fragments: [Fragment]
        var length: Int { skeletonLength + fragments.reduce(0) { $0 + $1.length } }
    }

    /// A `kindle:pos` target: a fragment and a byte in it.
    private struct Position: Hashable {
        var fragment: Int
        var offset: Int
    }

    private static let positionURL = try! NSRegularExpression(pattern: #"kindle:pos:fid:(\w+):off:(\w+)"#)
    private static let positionLink = try! NSRegularExpression(
        pattern: #"(\s(?:xlink:)?href\s*=\s*)(["'])kindle:pos:fid:(\w+):off:(\w+)\2"#, options: [.caseInsensitive])
    /// foliate's `getFragmentSelector`: a `kindle:pos` target is the first element
    /// at or after its byte with an `id`, a `name` or an `aid`.
    private static let anchorAttribute = try! NSRegularExpression(
        pattern: #"\s(id|name|aid)\s*=\s*(['"])([^'"]*)\2"#, options: [.caseInsensitive])
    private static let tagAttribute = try! NSRegularExpression(
        pattern: #"\s([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

    static func convert(_ file: MOBIFile) throws -> MOBIConvertedBook {
        precondition(file.kind == .kf8, "a MOBI 6 file goes to the MOBI 6 converter")
        // MOBIFile reads a part as KF8 only when it has these fields.
        let fields = file.headers.kf8!
        let encoding = file.headers.encoding
        let text = [UInt8](try file.text())
        let flows = try flowTable(file, fields, textLength: text.count)
        var warnings: [String] = []

        let skeletonRecord = file.partStart + Int(fields.skeletonIndex)
        var sections: [(section: Section, bytes: [UInt8])] = []
        for (index, section) in try sectionTable(file, fields).enumerated() {
            // foliate marks such a section non-linear and never loads it: it has no text.
            guard !section.fragments.isEmpty else {
                warnings.append("skeleton \(index) has no fragments and is left out")
                continue
            }
            sections.append((section, try assemble(section, text: text, flow: flows[0], record: skeletonRecord)))
        }
        var sectionOfFragment: [Int: Int] = [:]
        for (number, entry) in sections.enumerated() {
            for fragment in entry.section.fragments { sectionOfFragment[fragment.id] = number }
        }

        // Every element a link or the NCX points at, with the id to reach it by.
        let ncx = MOBINCXEntry.read(from: file, warnings: &warnings)
        let latin1 = sections.map { String(data: Data($0.bytes), encoding: .isoLatin1)! as NSString }
        var targets = Set(ncx.flatMap(Self.positions))
        for string in latin1 {
            for match in positionURL.matches(in: string as String, range: NSRange(location: 0, length: string.length)) {
                if let target = Self.position(string, match, fragment: 1, offset: 2) { targets.insert(target) }
            }
        }
        var anchors: [Position: (section: Int, id: String)] = [:]
        var insertions: [Int: [Int: [UInt8]]] = [:]
        for target in targets {
            guard let number = sectionOfFragment[target.fragment],
                  let fragment = sections[number].section.fragments.first(where: { $0.id == target.fragment }),
                  let anchor = try anchor(in: sections[number].bytes, latin1[number], encoding: encoding,
                                          from: fragment.insertOffset - sections[number].section.offset
                                              + target.offset)
            else { continue }
            if let insertion = anchor.insertion {
                insertions[number, default: [:]][insertion.at] = insertion.bytes
            }
            anchors[target] = (number, anchor.id)
        }
        func chapterFile(_ number: Int) -> String { String(format: "c%04d.xhtml", number + 1) }
        func href(for target: Position) -> String? {
            anchors[target].map { "\(chapterFile($0.section))#\($0.id)" }
        }

        let files = PackageFiles(file: file, text: text, flows: flows, encoding: encoding)
        var chapters: [MOBIConvertedBook.Chapter] = []
        for (number, entry) in sections.enumerated() {
            var bytes = entry.bytes
            for (at, insertion) in (insertions[number] ?? [:]).sorted(by: { $0.key > $1.key }) {
                bytes.insert(contentsOf: insertion, at: at)
            }
            var xhtml = encoding.decode(Data(bytes))
            xhtml = replacing(positionLink, in: xhtml) { match, string in
                let attribute = string.substring(with: match.range(at: 1))
                guard let target = Self.position(string, match, fragment: 3, offset: 4),
                      let href = href(for: target) else {
                    warnings.append("a link points at \(string.substring(with: match.range)), where no element is")
                    return ""
                }
                return attribute + "\"" + MOBIMarkupNormalizer.escaped(href) + "\""
            }
            xhtml = try files.rewrite(xhtml, inChapter: true)
            let parser = XMLParser(data: Data(xhtml.utf8))
            if !parser.parse() {
                warnings.append("\(chapterFile(number)) is not well-formed XML at line \(parser.lineNumber): "
                    + String(describing: parser.parserError))
            }
            let textLength = try SwiftSoup.parse(xhtml).body()?.text().utf16.count ?? 0
            chapters.append(.init(href: "text/" + chapterFile(number), xhtml: xhtml, textLength: textLength))
        }

        func toc(_ entry: MOBINCXEntry) -> [MOBIConvertedBook.TOCEntry] {
            let children = entry.children.flatMap(toc)
            guard let position = entry.position else { return children }
            guard let target = href(for: Position(fragment: position.fragment, offset: position.offset)) else {
                warnings.append("the table of contents entry «\(entry.title)» points at fragment "
                    + "\(position.fragment), byte \(position.offset), where no element is")
                return []
            }
            guard !entry.title.isEmpty else { return children }
            return [.init(title: entry.title, href: "text/" + target, children: children)]
        }
        let tableOfContents = ncx.flatMap(toc)

        let metadata = try file.metadata.entitiesDecoded()
        if let cover = metadata.coverResource {
            if let path = try files.embed(cover + 1),
               let index = files.resources.firstIndex(where: { $0.href == path }), path.hasPrefix("images/") {
                files.resources[index].isCover = true
            } else {
                warnings.append("the cover names resource \(cover), which holds no image")
            }
        }
        return MOBIConvertedBook(kind: .kf8, metadata: metadata, chapters: chapters,
                                 resources: files.resources.sorted { $0.href < $1.href }, toc: tableOfContents,
                                 warnings: warnings + files.warnings)
    }

    // MARK: Tables

    /// FDST: where each flow lies in the text. Flow 0 is the XHTML; a file with
    /// one flow has no table.
    private static func flowTable(_ file: MOBIFile, _ fields: KF8IndexFields,
                                  textLength: Int) throws -> [Range<Int>] {
        guard fields.fdstIndex != MOBIHeaders.nullIndex else { return [0..<textLength] }
        let record = file.partStart + Int(fields.fdstIndex)
        let reader = MOBIByteReader(try file.partRecord(Int(fields.fdstIndex)), record: record)
        guard try reader.magic(at: 0) == "FDST" else { throw MOBIError.corruptIndex(record: record) }
        var flows: [Range<Int>] = []
        for index in 0..<Int(try reader.uint32(at: 8)) {
            let start = Int(try reader.uint32(at: 12 + index * 8))
            let end = Int(try reader.uint32(at: 16 + index * 8))
            guard start <= end, end <= textLength else { throw MOBIError.corruptIndex(record: record) }
            flows.append(start..<end)
        }
        guard !flows.isEmpty else { throw MOBIError.corruptIndex(record: record) }
        return flows
    }

    /// The skeleton table, each skeleton with its share of the fragment table:
    /// they come in order, `numFrag` (tag 1) to a skeleton.
    private static func sectionTable(_ file: MOBIFile, _ fields: KF8IndexFields) throws -> [Section] {
        let fragmentRecord = file.partStart + Int(fields.fragmentIndex)
        let fragments = try MOBIIndex(file, record: Int(fields.fragmentIndex)).entries.map { entry in
            guard let insertOffset = Int(entry.name), let id = entry.tags[4]?.first,
                  let place = entry.tags[6], place.count >= 2
            else { throw MOBIError.corruptIndex(record: fragmentRecord) }
            return Fragment(insertOffset: insertOffset, id: id, offset: place[0], length: place[1])
        }
        let skeletonRecord = file.partStart + Int(fields.skeletonIndex)
        var next = 0
        return try MOBIIndex(file, record: Int(fields.skeletonIndex)).entries.map { entry in
            guard let count = entry.tags[1]?.first, let place = entry.tags[6], place.count >= 2,
                  next + count <= fragments.count
            else { throw MOBIError.corruptIndex(record: skeletonRecord) }
            defer { next += count }
            return Section(offset: place[0], skeletonLength: place[1], fragments: Array(fragments[next..<next + count]))
        }
    }

    /// foliate's `loadText`: the skeleton, with each fragment inserted where its
    /// entry says, in order.
    private static func assemble(_ section: Section, text: [UInt8], flow: Range<Int>,
                                 record: Int) throws -> [UInt8] {
        let end = section.offset + section.length
        guard section.offset >= flow.lowerBound, end <= flow.upperBound else {
            throw MOBIError.corruptIndex(record: record)
        }
        var bytes = Array(text[section.offset..<(section.offset + section.skeletonLength)])
        for fragment in section.fragments {
            let at = fragment.insertOffset - section.offset
            let start = section.offset + section.skeletonLength + fragment.offset
            guard at >= 0, at <= bytes.count, start + fragment.length <= end else {
                throw MOBIError.corruptIndex(record: record)
            }
            bytes.insert(contentsOf: text[start..<(start + fragment.length)], at: at)
        }
        return bytes
    }

    // MARK: Positions

    private static func positions(_ entry: MOBINCXEntry) -> [Position] {
        (entry.position.map { [Position(fragment: $0.fragment, offset: $0.offset)] } ?? [])
            + entry.children.flatMap(positions)
    }

    /// The fragment and offset of a `kindle:pos` URL, in base 32.
    private static func position(_ string: NSString, _ match: NSTextCheckingResult, fragment: Int,
                                 offset: Int) -> Position? {
        guard let id = Int(string.substring(with: match.range(at: fragment)), radix: 32),
              let byte = Int(string.substring(with: match.range(at: offset)), radix: 32) else { return nil }
        return Position(fragment: id, offset: byte)
    }

    /// The element a target byte names: the first tag at or after `start` with an
    /// `id`, `name` or `aid`, and the id to link to it by. A tag without an `id`
    /// gets one made from its `aid` or `name`, inserted after the tag name, with
    /// the attribute's own bytes and quotes.
    private static func anchor(in bytes: [UInt8], _ latin1: NSString, encoding: MOBITextEncoding,
                               from start: Int) throws -> (id: String, insertion: (at: Int, bytes: [UInt8])?)? {
        guard start >= 0, start < latin1.length else { return nil }
        func value(_ range: NSRange) throws -> String {
            try Entities.unescape(encoding.decode(Data(bytes[range.location..<(range.location + range.length)])))
        }
        var location = start
        while let match = anchorAttribute.firstMatch(
            in: latin1 as String, range: NSRange(location: location, length: latin1.length - location)) {
            location = match.range.location + match.range.length
            // Only an attribute: a `<` before it with no `>` between.
            var open = match.range.location - 1
            while open >= 0, bytes[open] != UInt8(ascii: "<"), bytes[open] != UInt8(ascii: ">") { open -= 1 }
            guard open >= 0, bytes[open] == UInt8(ascii: "<") else { continue }
            guard let close = bytes[location...].firstIndex(of: UInt8(ascii: ">")) else { return nil }

            // The tag's own id, wherever it sits among its attributes.
            let tag = NSRange(location: open, length: close + 1 - open)
            for attribute in tagAttribute.matches(in: latin1 as String, range: tag)
            where latin1.substring(with: attribute.range(at: 1)).lowercased() == "id" {
                let range = attribute.range(at: 2).location != NSNotFound ? attribute.range(at: 2) : attribute.range(at: 3)
                return (try value(range), nil)
            }
            let kind = latin1.substring(with: match.range(at: 1)).lowercased()
            let quote = Array(latin1.substring(with: match.range(at: 2)).utf8)
            let raw = match.range(at: 3)
            var nameEnd = open + 1
            while nameEnd < close, ![UInt8(ascii: " "), 0x09, 0x0A, 0x0D, UInt8(ascii: "/")].contains(bytes[nameEnd]) {
                nameEnd += 1
            }
            let insertion = Array(" id=".utf8) + quote + Array("\(kind)-".utf8)
                + bytes[raw.location..<(raw.location + raw.length)] + quote
            return ("\(kind)-" + (try value(raw)), (nameEnd, insertion))
        }
        return nil
    }

    // MARK: Resources

    /// The files `kindle:embed` and `kindle:flow` URLs name, each written once,
    /// when first met.
    private final class PackageFiles {
        private static let svgImage = try! NSRegularExpression(
            pattern: #"<img\b[^>]*?\ssrc\s*=\s*(["'])kindle:flow:(\w+)\?mime=image/svg\+xml\1[^>]*>"#,
            options: [.caseInsensitive])
        private static let url = try! NSRegularExpression(
            pattern: #"kindle:(flow|embed):(\w+)(?:\?mime=([\w/+.-]+))?"#)
        private static let prolog = try! NSRegularExpression(
            pattern: #"^\s*(?:<\?xml[^>]*\?>\s*)?(?:<!DOCTYPE[^>]*>\s*)?"#, options: [.caseInsensitive])

        let file: MOBIFile
        let text: [UInt8]
        let flows: [Range<Int>]
        let encoding: MOBITextEncoding
        var resources: [MOBIConvertedBook.Resource] = []
        var warnings: [String] = []
        private var embeds: [Int: String?] = [:]
        private var flowFiles: [Int: String?] = [:]

        init(file: MOBIFile, text: [UInt8], flows: [Range<Int>], encoding: MOBITextEncoding) {
            self.file = file
            self.text = text
            self.flows = flows
            self.encoding = encoding
        }

        /// `markup` with every `kindle:` resource URL pointing at its package file
        /// and, in a chapter, every SVG `<img>` replaced by the SVG: a picture the
        /// SVG draws (Calibre's cover wrapper) cannot load from an SVG used as an
        /// image, which is why the source had it inline. Chapters, stylesheets and
        /// pictures all sit one folder down, so every path starts `../`.
        func rewrite(_ markup: String, inChapter: Bool) throws -> String {
            var markup = markup
            if inChapter {
                markup = replacing(Self.svgImage, in: markup) { match, string in
                    Int(string.substring(with: match.range(at: 2)), radix: 32).flatMap(self.inlineSVG)
                }
            }
            return try replacing(Self.url, in: markup) { match, string in
                let number = Int(string.substring(with: match.range(at: 2)), radix: 32)
                let mime = match.range(at: 3).location == NSNotFound ? nil : string.substring(with: match.range(at: 3))
                let href = string.substring(with: match.range(at: 1)) == "embed"
                    ? try number.flatMap { try self.embed($0) }
                    : try number.flatMap { try self.flow($0, mime: mime) }
                guard let href else {
                    self.warnings.append("\(string.substring(with: match.range)) could not be carried over")
                    return nil
                }
                return "../" + href
            }
        }

        /// The package path of resource `number` (1-based, as `kindle:embed` counts),
        /// a picture or a font, or nil when the record is neither.
        func embed(_ number: Int) throws -> String? {
            if let href = embeds[number] { return href }
            var href: String?
            let index = number - 1
            if index >= 0, file.resourceStart + index < file.recordCount {
                var data = try file.resource(index)
                var type = MOBIConvertedBook.Resource.imageType(of: data)
                var folder = "images/image"
                if data.prefix(4) == Data("FONT".utf8) {
                    do {
                        data = try KF8Converter.font(data)
                        type = MOBIConvertedBook.Resource.fontType(of: data)
                        folder = "fonts/font"
                        if type == nil { warnings.append("font resource \(number) is in no format a reader knows") }
                    } catch {
                        warnings.append("font resource \(number) could not be read: \(error)")
                        type = nil
                    }
                }
                if let type {
                    href = folder + String(format: "%05d.%@", number, type.extension)
                    resources.append(.init(href: href!, mediaType: type.mediaType, data: data, isCover: false))
                }
            }
            embeds[number] = href
            return href
        }

        /// The package path of flow `number`: stylesheets in `style/`, SVG in
        /// `images/`, each rewritten in turn.
        private func flow(_ number: Int, mime: String?) throws -> String? {
            if let href = flowFiles[number] { return href }
            let place = ["text/css": "style/flow%04d.css", "image/svg+xml": "images/flow%04d.svg"][mime ?? ""]
            guard number >= 1, number < flows.count, let place, let mime else {
                flowFiles[number] = String?.none
                return nil
            }
            let href = String(format: place, number)
            // Recorded first: a flow that names itself must not recurse.
            flowFiles[number] = href
            let markup = try rewrite(flowText(number), inChapter: false)
            resources.append(.init(href: href, mediaType: mime, data: Data(markup.utf8), isCover: false))
            return href
        }

        /// SVG flow `number` as markup to put in a chapter: without its XML
        /// declaration and doctype, which only a document may have.
        private func inlineSVG(_ number: Int) -> String? {
            guard number >= 1, number < flows.count else { return nil }
            let svg = flowText(number)
            let prolog = Self.prolog.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg))
            let body = prolog.map { (svg as NSString).substring(from: $0.range.length) } ?? svg
            guard body.hasPrefix("<svg") else { return nil }
            return body
        }

        private func flowText(_ number: Int) -> String {
            encoding.decode(Data(text[flows[number]]))
        }
    }

    /// A `FONT` record's font: XOR-obfuscated in its first 1040 bytes (1024 with a
    /// 16-byte key) when flag 2 is set, then zlib-compressed when flag 1 is.
    static func font(_ record: Data) throws -> Data {
        let reader = MOBIByteReader(record, record: nil)
        let flags = try reader.uint32(at: 8)
        let dataStart = Int(try reader.uint32(at: 12))
        var data = [UInt8](try reader.data(at: dataStart, count: reader.count - dataStart))
        if flags & 0b10 != 0 {
            let keyLength = Int(try reader.uint32(at: 16))
            let key = [UInt8](try reader.data(at: Int(try reader.uint32(at: 20)), count: keyLength))
            if !key.isEmpty {
                for index in 0..<min(keyLength == 16 ? 1024 : 1040, data.count) {
                    data[index] ^= key[index % key.count]
                }
            }
        }
        guard flags & 0b1 != 0 else { return Data(data) }
        // CJK fonts run to tens of megabytes; past this a record is not a font.
        return try GzipDecoder.decompressZlib(Data(data), maximumBytes: 64 << 20)
    }
}

/// `string` with every match of `regex` replaced by what `replacement` returns,
/// or left as it is where it returns nil.
private func replacing(_ regex: NSRegularExpression, in string: String,
                       with replacement: (NSTextCheckingResult, NSString) throws -> String?) rethrows -> String {
    let text = string as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: string, range: NSRange(location: 0, length: text.length)) {
        result += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        result += try replacement(match, text) ?? text.substring(with: match.range)
        cursor = match.range.location + match.range.length
    }
    return result + text.substring(from: cursor)
}
