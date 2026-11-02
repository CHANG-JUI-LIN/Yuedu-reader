// Ported from foliate-js `mobi.js` (MIT, Copyright (c) 2022 John Factotum).
// The full licence is in foliate-js-LICENSE.txt beside this file.

import Foundation

/// PalmDOC (LZ77) decompression, MOBI compression type 2, one text record at a time.
///
/// foliate reads past the input silently where JavaScript returns `undefined`;
/// here a literal run, a back-reference or a pair cut off by the end of the record
/// is `corruptText` instead, because indexing past an array in Swift traps.
enum PalmDOCDecompressor {
    static func decompress(_ input: Data, record: Int) throws -> Data {
        var output = [UInt8]()
        output.reserveCapacity(input.count * 2)
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case 0x01...0x08:
                    // The next 1–8 bytes are literals.
                    let end = index + Int(byte)
                    guard end <= bytes.count else { throw MOBIError.corruptText(record: record) }
                    output.append(contentsOf: bytes[index..<end])
                    index = end
                case 0x80...0xBF:
                    // A length–distance pair: 2 marker bits, 11 bits of distance,
                    // 3 bits of length − 3.
                    guard index < bytes.count else { throw MOBIError.corruptText(record: record) }
                    let pair = Int(byte) << 8 | Int(bytes[index])
                    index += 1
                    let distance = (pair & 0x3FFF) >> 3
                    let length = (pair & 0x07) + 3
                    guard distance > 0, distance <= output.count else {
                        throw MOBIError.corruptText(record: record)
                    }
                    // Byte by byte: a distance shorter than the length repeats
                    // bytes this same copy is writing.
                    for _ in 0..<length {
                        output.append(output[output.count - distance])
                    }
                case 0xC0...0xFF:
                    // A space followed by the byte with its top bit cleared.
                    output.append(0x20)
                    output.append(byte ^ 0x80)
                default:
                    // 0x00 and 0x09…0x7F are themselves.
                    output.append(byte)
                }
            }
        }
        return Data(output)
    }
}

/// The extra bytes KindleGen and Calibre append to each text record, described by
/// the MOBI header's extra-record-data flags (offset 0xF2).
///
/// Bit 0 is the multibyte entry: the 1–4 bytes of a character cut by the record
/// boundary, repeated at the end of the record and always stripped. Every higher
/// set bit is one entry whose size is a backward variable-length integer at its
/// end. They are stripped from the end inward, the multibyte entry last, as
/// Calibre's `sizeof_trailing_entries` and foliate's `removeTrailingEntries` do.
struct MOBITrailingEntries: Sendable, Equatable {
    let flags: UInt16

    func strip(_ record: Data, index: Int) throws -> Data {
        guard flags != 0 else { return record }
        let bytes = MOBIByteReader(record, record: index)
        var trailing = 0
        var remaining = flags >> 1
        while remaining != 0 {
            if remaining & 1 == 1 {
                trailing += try Self.entrySize(bytes, endingAt: bytes.count - trailing, record: index)
            }
            remaining >>= 1
        }
        if flags & 1 == 1 {
            guard trailing < bytes.count else { throw MOBIError.corruptText(record: index) }
            trailing += Int(try bytes.uint8(at: bytes.count - trailing - 1) & 0x03) + 1
        }
        guard trailing <= bytes.count else { throw MOBIError.corruptText(record: index) }
        return bytes.bytes.prefix(bytes.count - trailing)
    }

    /// A size stored as up to four 7-bit groups read backwards from `end`; the
    /// group with the top bit set is the first, and the size counts itself.
    private static func entrySize(_ bytes: MOBIByteReader, endingAt end: Int, record: Int) throws -> Int {
        var value = 0
        var shift = 0
        var position = end
        while true {
            guard position > 0 else { throw MOBIError.corruptText(record: record) }
            position -= 1
            let byte = try bytes.uint8(at: position)
            value |= Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 != 0 || shift >= 28 { return value }
        }
    }
}
