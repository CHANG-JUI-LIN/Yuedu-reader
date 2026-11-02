// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation

/// Why a Mobipocket or KF8 file could not be read. The importer logs every case;
/// `encrypted` and `unknownCompression` have messages of their own, the rest
/// share 「無法讀取這個 Kindle 檔案」 (`MOBIBookImporter.swift`).
enum MOBIError: Error, Equatable, Sendable {
    /// No `BOOKMOBI` at offset 60: some other PalmDB file, or not a PalmDB at all.
    case notMOBI
    /// The PalmDOC `encryption` field is not 0. Never decrypted.
    case encrypted(UInt16)
    /// Compression other than 1 (none) or 2 (PalmDOC). HUFF/CDIC (17480) is
    /// refused until a DRM-free sample has run through a test.
    case unknownCompression(UInt16)
    /// A text encoding other than 1252 (cp1252) or 65001 (UTF-8), the only two
    /// the format defines.
    case unsupportedEncoding(UInt32)
    /// The record that should hold a MOBI header does not.
    case missingMOBIHeader(record: Int)
    /// A read past the end of a record, or a record that runs past the file;
    /// `nil` is the PalmDB header and its record table.
    case truncatedRecord(Int?)
    /// A text record whose compressed data or trailing entries do not add up.
    case corruptText(record: Int)
    /// An index record (`INDX`/`TAGX`) or KF8 flow table (`FDST`) that is not
    /// one, or that runs past itself or the text.
    case corruptIndex(record: Int)
}

/// Big-endian reads that throw instead of trapping: every offset and length in a
/// MOBI file comes from the file itself, so none is trusted.
struct MOBIByteReader: Sendable {
    let bytes: Data
    /// The absolute record index, for errors; `nil` for the PalmDB header.
    let record: Int?

    init(_ bytes: Data, record: Int?) {
        // A slice keeps its parent's indices; every offset below is from 0.
        self.bytes = bytes.startIndex == 0 ? bytes : Data(bytes)
        self.record = record
    }

    var count: Int { bytes.count }

    func uint8(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < bytes.count else { throw MOBIError.truncatedRecord(record) }
        return bytes[offset]
    }

    func uint16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { throw MOBIError.truncatedRecord(record) }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw MOBIError.truncatedRecord(record) }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    func data(at offset: Int, count length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= bytes.count - length else {
            throw MOBIError.truncatedRecord(record)
        }
        return bytes.subdata(in: offset..<(offset + length))
    }

    /// Bytes from `offset` to the end of the record.
    func data(from offset: Int) throws -> Data {
        try data(at: offset, count: bytes.count - offset)
    }

    /// Four bytes read as ASCII, for record magics (`MOBI`, `EXTH`, `FDST`…).
    func magic(at offset: Int) throws -> String {
        String(decoding: try data(at: offset, count: 4), as: UTF8.self)
    }
}

/// The two text encodings a MOBI header can name.
enum MOBITextEncoding: Sendable, Equatable {
    case cp1252
    case utf8

    init(code: UInt32) throws {
        switch code {
        case 1252: self = .cp1252
        case 65001: self = .utf8
        default: throw MOBIError.unsupportedEncoding(code)
        }
    }

    /// Decodes as a browser's `TextDecoder` does, which is what foliate relies on:
    /// a bad UTF-8 sequence becomes U+FFFD, and cp1252 is WHATWG's windows-1252,
    /// where the five bytes Microsoft left undefined map to the C1 control of the
    /// same value. Foundation's `.windowsCP1252` instead fails the whole string.
    func decode(_ bytes: Data) -> String {
        switch self {
        case .utf8:
            return String(decoding: bytes, as: UTF8.self)
        case .cp1252:
            var scalars = String.UnicodeScalarView()
            scalars.reserveCapacity(bytes.count)
            for byte in bytes {
                let value = (0x80...0x9F).contains(byte)
                    ? Self.cp1252High[Int(byte) - 0x80] : UInt32(byte)
                // Every table entry and every Latin-1 value is a valid scalar.
                scalars.append(Unicode.Scalar(value)!)
            }
            return String(scalars)
        }
    }

    /// windows-1252 for 0x80…0x9F (WHATWG Encoding Standard index).
    private static let cp1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]
}
