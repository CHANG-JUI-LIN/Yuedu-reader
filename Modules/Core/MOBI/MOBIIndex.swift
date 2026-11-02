// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation
import SwiftSoup

/// A Mobipocket index (`INDX` records with a `TAGX` table and `CNCX` strings),
/// foliate's `getIndexData`. KF8's skeleton, fragment and guide tables and every
/// file's table of contents (the NCX) are indexes.
struct MOBIIndex: Sendable {
    struct Entry: Sendable, Equatable {
        /// The entry's key: a skeleton's name, a fragment's insert offset in
        /// decimal, a guide reference's type.
        var name: String
        /// Values by tag number. A tag the entry does not carry is absent.
        var tags: [UInt8: [Int]]
    }

    var entries: [Entry]
    /// The `CNCX` strings, by the offset entries name them with: the record's
    /// number times 0x10000 plus the position in the record.
    var strings: [Int: String]

    /// Reads the index whose header is part record `index` (KF8 index fields and
    /// the NCX field count from the start of the part).
    init(_ file: MOBIFile, record index: Int) throws {
        let absolute = file.partStart + index
        let header = MOBIByteReader(try file.partRecord(index), record: absolute)
        guard try header.magic(at: 0) == "INDX" else { throw MOBIError.corruptIndex(record: absolute) }
        let headerLength = Int(try header.uint32(at: 4))
        let recordCount = Int(try header.uint32(at: 24))
        let encoding = try MOBITextEncoding(code: header.uint32(at: 28))
        let stringRecordCount = Int(try header.uint32(at: 52))

        // TAGX: the tags an entry may carry, four bytes each.
        guard try header.magic(at: headerLength) == "TAGX" else { throw MOBIError.corruptIndex(record: absolute) }
        let tagxLength = Int(try header.uint32(at: headerLength + 4))
        let controlByteCount = Int(try header.uint32(at: headerLength + 8))
        guard tagxLength >= 12, (tagxLength - 12) % 4 == 0 else { throw MOBIError.corruptIndex(record: absolute) }
        var tagTable: [TagDefinition] = []
        for offset in stride(from: headerLength + 12, to: headerLength + tagxLength, by: 4) {
            tagTable.append(TagDefinition(tag: try header.uint8(at: offset),
                                          valuesPerEntry: Int(try header.uint8(at: offset + 1)),
                                          mask: try header.uint8(at: offset + 2),
                                          endsControlByte: try header.uint8(at: offset + 3) & 1 == 1))
        }

        var strings: [Int: String] = [:]
        for number in 0..<stringRecordCount {
            let recordIndex = index + recordCount + 1 + number
            let reader = MOBIByteReader(try file.partRecord(recordIndex), record: file.partStart + recordIndex)
            // Writers pad the record with zeros to a multiple of four.
            let end = (reader.bytes.lastIndex { $0 != 0 } ?? -1) + 1
            var position = 0
            while position < end {
                let start = position
                let length = try Self.varLength(reader, at: &position)
                strings[number * 0x10000 + start] = encoding.decode(try reader.data(at: position, count: length))
                position += length
            }
        }

        var entries: [Entry] = []
        for number in 0..<recordCount {
            let recordIndex = index + 1 + number
            let reader = MOBIByteReader(try file.partRecord(recordIndex), record: file.partStart + recordIndex)
            guard try reader.magic(at: 0) == "INDX" else {
                throw MOBIError.corruptIndex(record: file.partStart + recordIndex)
            }
            let idxt = Int(try reader.uint32(at: 20))
            let entryCount = Int(try reader.uint32(at: 24))
            for entryNumber in 0..<entryCount {
                let offset = Int(try reader.uint16(at: idxt + 4 + 2 * entryNumber))
                entries.append(try Self.entry(reader, at: offset, tagTable: tagTable,
                                              controlByteCount: controlByteCount))
            }
        }
        self.entries = entries
        self.strings = strings
    }

    private struct TagDefinition {
        var tag: UInt8
        var valuesPerEntry: Int
        var mask: UInt8
        var endsControlByte: Bool
    }

    private static func entry(_ reader: MOBIByteReader, at offset: Int, tagTable: [TagDefinition],
                              controlByteCount: Int) throws -> Entry {
        let nameLength = Int(try reader.uint8(at: offset))
        let name = String(decoding: try reader.data(at: offset + 1, count: nameLength), as: UTF8.self)
        let controlStart = offset + 1 + nameLength
        var position = controlStart + controlByteCount

        // Each tag's count: from its control-byte bits, or, when the bits are all
        // set and span more than one bit, from a length in bytes that follows.
        var counts: [(tag: TagDefinition, valueCount: Int?, byteCount: Int?)] = []
        var controlByte = 0
        for definition in tagTable {
            if definition.endsControlByte {
                controlByte += 1
                continue
            }
            let value = try reader.uint8(at: controlStart + controlByte) & definition.mask
            if value == definition.mask {
                if definition.mask.nonzeroBitCount > 1 {
                    counts.append((definition, nil, try varLength(reader, at: &position)))
                } else {
                    counts.append((definition, 1, nil))
                }
            } else {
                counts.append((definition, Int(value >> definition.mask.trailingZeroBitCount), nil))
            }
        }

        var tags: [UInt8: [Int]] = [:]
        for (definition, valueCount, byteCount) in counts {
            var values: [Int] = []
            if let valueCount {
                for _ in 0..<(valueCount * definition.valuesPerEntry) {
                    values.append(try varLength(reader, at: &position))
                }
            } else if let byteCount {
                let end = position + byteCount
                while position < end {
                    values.append(try varLength(reader, at: &position))
                }
            }
            if !values.isEmpty { tags[definition.tag] = values }
        }
        return Entry(name: name, tags: tags)
    }

    /// A forward variable-length number: seven bits a byte, the high bit set on
    /// the last, at most four bytes.
    private static func varLength(_ reader: MOBIByteReader, at position: inout Int) throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try reader.uint8(at: position)
            position += 1
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 != 0 { break }
        }
        return value
    }
}

/// A table of contents read from a file's NCX index (foliate's `getNCX`).
struct MOBINCXEntry: Sendable, Equatable {
    var title: String
    /// MOBI 6: the text byte the entry points at (tag 1).
    var offset: Int?
    /// KF8: the fragment and the byte in it (tag 6).
    var position: (fragment: Int, offset: Int)?
    var children: [MOBINCXEntry]

    static func == (lhs: MOBINCXEntry, rhs: MOBINCXEntry) -> Bool {
        lhs.title == rhs.title && lhs.offset == rhs.offset && lhs.position?.fragment == rhs.position?.fragment
            && lhs.position?.offset == rhs.position?.offset && lhs.children == rhs.children
    }

    /// The entries at heading level 0, each with its children (tag 21 names an
    /// entry's parent). An entry is placed once, so a parent loop in a damaged
    /// file cannot recurse.
    static func tree(_ index: MOBIIndex) -> [MOBINCXEntry] {
        let entries = index.entries
        var childrenOf: [Int: [Int]] = [:]
        for (number, entry) in entries.enumerated() {
            if let parent = entry.tags[21]?.first { childrenOf[parent, default: []].append(number) }
        }
        var placed = Set<Int>()
        func build(_ number: Int) -> MOBINCXEntry? {
            guard placed.insert(number).inserted else { return nil }
            let tags = entries[number].tags
            let position = tags[6].flatMap { $0.count >= 2 ? (fragment: $0[0], offset: $0[1]) : nil }
            return MOBINCXEntry(title: tags[3].flatMap { $0.first }.flatMap { index.strings[$0] } ?? "",
                                offset: tags[1]?.first, position: position,
                                children: (childrenOf[number] ?? []).compactMap(build))
        }
        return entries.indices.filter { entries[$0].tags[4]?.first == 0 }.compactMap(build)
    }

    /// The file's NCX, labels unescaped: the Kindle tools store them as written,
    /// entities and all. The table of contents is navigation, not text, so an
    /// index that cannot be read leaves the book without one, with a warning.
    static func read(from file: MOBIFile, warnings: inout [String]) -> [MOBINCXEntry] {
        guard file.headers.ncxIndex != MOBIHeaders.nullIndex else { return [] }
        do {
            func unescaped(_ entry: MOBINCXEntry) throws -> MOBINCXEntry {
                var entry = entry
                entry.title = try Entities.unescape(entry.title)
                entry.children = try entry.children.map(unescaped)
                return entry
            }
            return try tree(try MOBIIndex(file, record: Int(file.headers.ncxIndex))).map(unescaped)
        } catch {
            warnings.append("the NCX index could not be read: \(error)")
            return []
        }
    }
}
