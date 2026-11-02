// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation

/// The headers at the start of a MOBI part's first record: PalmDOC, MOBI, the
/// optional EXTH block and, for KF8, the extra index fields.
///
/// Fields the MOBI header gained over the years are read only when the header is
/// long enough to hold them, following Calibre's `BookHeader` rather than foliate
/// (which reads fixed offsets regardless): an old short header leaves EXTH or the
/// next record's bytes at those offsets.
struct MOBIHeaders: Sendable {
    /// "No such record" in every index field of the format.
    static let nullIndex: UInt32 = 0xFFFF_FFFF

    // PalmDOC header (record offset 0)
    let compression: UInt16
    /// Uncompressed length of all text records together.
    let textLength: UInt32
    let textRecordCount: Int
    let textRecordSize: Int
    let encryption: UInt16

    // MOBI header (record offset 16)
    let headerLength: Int
    let bookType: UInt32
    let encoding: MOBITextEncoding
    let uniqueID: UInt32
    let version: UInt32
    /// The header's own copy of the title; EXTH 503 wins when present.
    let fullName: String?
    /// Locale field (offset 0x5C): language id in the low byte, region id in bits 10–15.
    let locale: UInt32
    /// First resource record, as an absolute record index in record 0 and
    /// relative to the KF8 part in a combo file's KF8 header.
    let resourceStart: UInt32
    let huffCDICRecord: UInt32
    let huffCDICCount: UInt32
    let extraRecordDataFlags: UInt16
    /// The NCX index (KF8) or the MOBI 6 index, relative to the part.
    let ncxIndex: UInt32
    let exth: EXTHRecords?
    let kf8: KF8IndexFields?

    init(record: Data, index: Int) throws {
        let bytes = MOBIByteReader(record, record: index)
        compression = try bytes.uint16(at: 0)
        textLength = try bytes.uint32(at: 4)
        textRecordCount = Int(try bytes.uint16(at: 8))
        textRecordSize = Int(try bytes.uint16(at: 10))
        encryption = try bytes.uint16(at: 12)

        guard bytes.count >= 20, try bytes.magic(at: 16) == "MOBI" else {
            throw MOBIError.missingMOBIHeader(record: index)
        }
        headerLength = Int(try bytes.uint32(at: 20))
        bookType = try bytes.uint32(at: 24)
        encoding = try MOBITextEncoding(code: bytes.uint32(at: 28))
        uniqueID = try bytes.uint32(at: 32)
        version = try bytes.uint32(at: 36)

        let titleOffset = Int(try bytes.uint32(at: 0x54))
        let titleLength = Int(try bytes.uint32(at: 0x58))
        // A title outside the record is a missing title, as in Calibre; the
        // header is otherwise usable and EXTH usually carries the title anyway.
        if titleOffset <= bytes.count, titleLength <= bytes.count - titleOffset {
            fullName = encoding.decode(try bytes.data(at: titleOffset, count: titleLength))
        } else {
            fullName = nil
        }
        locale = try bytes.uint32(at: 0x5C)
        resourceStart = try bytes.uint32(at: 0x6C)
        huffCDICRecord = try bytes.uint32(at: 0x70)
        huffCDICCount = try bytes.uint32(at: 0x74)

        // Calibre: the flags exist for header lengths 0xE4…500 (KindleGen 2.9
        // writes 264). Below that, offset 0xF2 is past the header.
        if (0xE4...500).contains(headerLength) {
            extraRecordDataFlags = try bytes.uint16(at: 0xF2)
        } else {
            extraRecordDataFlags = 0
        }
        // The index field ends at 0xF8, inside headers of 0xE8 and longer; a
        // shorter header has EXTH or the title there.
        ncxIndex = headerLength >= 0xE8 ? try bytes.uint32(at: 0xF4) : Self.nullIndex

        let exthFlag = try bytes.uint32(at: 0x80)
        exth = exthFlag & 0x40 != 0
            ? try EXTHRecords(bytes, offset: 16 + headerLength, encoding: encoding)
            : nil

        // Calibre: ancient PRC files can carry any version number, so version 8
        // alone is not trusted to mean the KF8 fields are there. The last of them
        // ends at 0x108, inside headers of 0xF8 and longer.
        if version == 8, headerLength >= 0xF8 {
            kf8 = try KF8IndexFields(bytes)
        } else {
            kf8 = nil
        }
    }
}

/// The KF8 header's index records, relative to the KF8 part.
struct KF8IndexFields: Sendable {
    let fdstIndex: UInt32
    let fdstCount: UInt32
    let fragmentIndex: UInt32
    let skeletonIndex: UInt32
    let guideIndex: UInt32

    fileprivate init(_ bytes: MOBIByteReader) throws {
        let fdstCount = try bytes.uint32(at: 0xC4)
        // Calibre: with one flow or none, the FDST index field can be garbage.
        fdstIndex = fdstCount > 1 ? try bytes.uint32(at: 0xC0) : MOBIHeaders.nullIndex
        self.fdstCount = fdstCount
        fragmentIndex = try bytes.uint32(at: 0xF8)
        skeletonIndex = try bytes.uint32(at: 0xFC)
        guideIndex = try bytes.uint32(at: 0x104)
    }
}

/// The EXTH block: typed metadata records after the MOBI header.
struct EXTHRecords: Sendable {
    /// Every record's payload by type, in file order; a type can repeat
    /// (authors, subjects, languages).
    let values: [UInt32: [Data]]
    let encoding: MOBITextEncoding

    fileprivate init(_ bytes: MOBIByteReader, offset: Int, encoding: MOBITextEncoding) throws {
        guard try bytes.magic(at: offset) == "EXTH" else {
            throw MOBIError.truncatedRecord(bytes.record)
        }
        let count = try bytes.uint32(at: offset + 8)
        var values: [UInt32: [Data]] = [:]
        var position = offset + 12
        for _ in 0..<count {
            let type = try bytes.uint32(at: position)
            let length = Int(try bytes.uint32(at: position + 4))
            // The length counts its own 8-byte type and length.
            guard length >= 8 else { throw MOBIError.truncatedRecord(bytes.record) }
            values[type, default: []].append(try bytes.data(at: position + 8, count: length - 8))
            position += length
        }
        self.values = values
        self.encoding = encoding
    }

    func strings(_ type: EXTHType) -> [String] {
        (values[type.rawValue] ?? []).map(encoding.decode)
    }

    func string(_ type: EXTHType) -> String? {
        strings(type).first
    }

    /// A 4-byte big-endian number; `nil` when absent, the wrong size or the null index.
    func number(_ type: EXTHType) -> UInt32? {
        guard let data = values[type.rawValue]?.first, data.count == 4 else { return nil }
        let value = data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return value == MOBIHeaders.nullIndex ? nil : value
    }
}

/// The EXTH record types this reader uses (foliate's `EXTH_RECORD_TYPE`).
enum EXTHType: UInt32, Sendable {
    case creator = 100
    case publisher = 101
    case description = 103
    case isbn = 104
    case subject = 105
    case date = 106
    case contributor = 108
    case rights = 109
    case subjectCode = 110
    case source = 112
    case asin = 113
    /// Combo files: the KF8 part's first record.
    case kf8Boundary = 121
    case fixedLayout = 122
    case resourceCount = 125
    case originalResolution = 126
    case zeroGutter = 127
    case zeroMargin = 128
    case coverURI = 129
    case regionMagnification = 132
    case coverOffset = 201
    case thumbnailOffset = 202
    case title = 503
    case language = 524
    case primaryWritingMode = 525
    case pageProgressionDirection = 527
}
