// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation

/// A Mobipocket (`.mobi`, `.prc`, `.azw`) or KF8 (`.azw3`) file: the PalmDB record
/// table, and the headers of the part the book is read from.
///
/// A combo file carries the same book twice, MOBI 6 first and KF8 after a
/// `BOUNDARY` record; like foliate and Calibre, the KF8 part is the one read.
/// The format, not the file name, decides: `.mobi` files are often KF8 or combo.
struct MOBIFile: Sendable {
    enum Kind: String, Sendable, Codable {
        case mobi6
        case kf8
    }

    let data: Data
    /// The PalmDB name: a 31-byte, underscore-mangled title.
    let databaseName: String
    let kind: Kind
    /// First record of the part being read: 0, or the KF8 part of a combo file.
    let partStart: Int
    /// The headers of the part being read.
    let headers: MOBIHeaders
    /// Absolute index of the first resource (image, font) record. Always record
    /// 0's value: a combo file's two parts share one set of resources, which sits
    /// in the MOBI 6 part, and its KF8 header's value is relative to the KF8 part
    /// (foliate captures it before switching parts for the same reason).
    let resourceStart: Int
    private let recordStarts: [Int]

    /// PalmDB type and creator at offset 60. Calibre compares them uppercased.
    static func isMOBI(_ data: Data) -> Bool {
        guard data.count >= 68 else { return false }
        let start = data.startIndex + 60
        return String(decoding: data[start..<(start + 8)], as: UTF8.self).uppercased() == "BOOKMOBI"
    }

    init(data: Data) throws {
        let data = data.startIndex == 0 ? data : Data(data)
        guard Self.isMOBI(data) else { throw MOBIError.notMOBI }
        let header = MOBIByteReader(data, record: nil)
        let recordCount = Int(try header.uint16(at: 76))
        var recordStarts: [Int] = []
        recordStarts.reserveCapacity(recordCount)
        for index in 0..<recordCount {
            recordStarts.append(Int(try header.uint32(at: 78 + index * 8)))
        }
        self.data = data
        self.recordStarts = recordStarts
        databaseName = MOBITextEncoding.cp1252.decode(
            try header.data(at: 0, count: 32).prefix { $0 != 0 })

        let first = try MOBIHeaders(record: Self.record(0, in: data, starts: recordStarts), index: 0)
        // Checked on record 0 before anything else: a DRM'd combo file is DRM'd
        // in both parts, and nothing past this point should read its text.
        guard first.encryption == 0 else { throw MOBIError.encrypted(first.encryption) }
        resourceStart = Int(first.resourceStart)

        if first.version == 8, let kf8 = first.kf8, kf8.skeletonIndex != MOBIHeaders.nullIndex {
            kind = .kf8
            partStart = 0
            headers = first
        } else if let boundary = first.exth?.number(.kf8Boundary).map(Int.init), boundary > 0,
                  boundary < recordStarts.count,
                  try Self.record(boundary - 1, in: data, starts: recordStarts).prefix(8)
                    == Data("BOUNDARY".utf8) {
            // Calibre's test for a combo ("joint") file. Without the marker the
            // EXTH value is ignored and the MOBI 6 text is the book, as there.
            let part = try MOBIHeaders(record: Self.record(boundary, in: data, starts: recordStarts),
                                       index: boundary)
            guard part.encryption == 0 else { throw MOBIError.encrypted(part.encryption) }
            // The marker promises a KF8 part; one without its index fields is
            // broken, not a reason to read the MOBI 6 part instead.
            guard part.version == 8, let kf8 = part.kf8, kf8.skeletonIndex != MOBIHeaders.nullIndex else {
                throw MOBIError.missingMOBIHeader(record: boundary)
            }
            kind = .kf8
            partStart = boundary
            headers = part
        } else {
            kind = .mobi6
            partStart = 0
            headers = first
        }

        // foliate's `setup`: none or PalmDOC. HUFF/CDIC (17480) waits for a
        // DRM-free sample; anything else is not a compression the format has.
        guard headers.compression == 1 || headers.compression == 2 else {
            throw MOBIError.unknownCompression(headers.compression)
        }
    }

    var recordCount: Int { recordStarts.count }

    /// A record by absolute index.
    func record(_ index: Int) throws -> Data {
        try Self.record(index, in: data, starts: recordStarts)
    }

    /// A record by index within the part being read; the KF8 header's index
    /// fields (FDST, skeleton, fragment, NCX, guide) count from there.
    func partRecord(_ index: Int) throws -> Data {
        try record(partStart + index)
    }

    /// Text record `index` (0-based) with its trailing entries removed and
    /// decompressed. Raw bytes, not a string: MOBI 6 links (`filepos`) and KF8
    /// fragment tables are byte offsets into the concatenated text.
    func textRecord(_ index: Int) throws -> Data {
        guard index >= 0, index < headers.textRecordCount else {
            throw MOBIError.truncatedRecord(partStart + 1 + index)
        }
        let absolute = partStart + 1 + index
        let stripped = try MOBITrailingEntries(flags: headers.extraRecordDataFlags)
            .strip(record(absolute), index: absolute)
        switch headers.compression {
        case 2: return try PalmDOCDecompressor.decompress(stripped, record: absolute)
        default: return stripped
        }
    }

    /// Every text record, concatenated: the book's whole markup (MOBI 6) or all
    /// of its flows (KF8).
    func text() throws -> Data {
        var text = Data()
        text.reserveCapacity(Int(headers.textLength))
        for index in 0..<headers.textRecordCount {
            text.append(try textRecord(index))
        }
        return text
    }

    /// Resource `index` (images, fonts…), counted from the first resource record.
    /// MOBI 6 `recindex` attributes are 1-based and KF8 `kindle:embed` numbers
    /// are base-32 and 1-based; callers subtract the 1.
    func resource(_ index: Int) throws -> Data {
        try record(resourceStart + index)
    }

    private static func record(_ index: Int, in data: Data, starts: [Int]) throws -> Data {
        guard index >= 0, index < starts.count else { throw MOBIError.truncatedRecord(index) }
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] : data.count
        guard start <= end, end <= data.count else { throw MOBIError.truncatedRecord(index) }
        return data.subdata(in: start..<end)
    }
}
