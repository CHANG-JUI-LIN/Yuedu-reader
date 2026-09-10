import Foundation

/// Gives a colliding embedded TrueType face a private name without changing
/// its glyphs, metrics, shaping tables, or authored CSS family alias.
enum EmbeddedTrueTypeFontIdentity {
    static func namespaced(_ data: Data, digest: String) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, [UInt32(0x00010000), 0x74727565].contains(u32(bytes, 0)) else { return nil }
        let count = Int(u16(bytes, 4))
        guard count > 0, count <= 4095, count <= (bytes.count - 12) / 16 else { return nil }
        var tables: [(tag: UInt32, bytes: [UInt8])] = []
        let identity = "YueduEmbedded-" + digest.prefix(32)
        var replacedName = false
        for index in 0..<count {
            let record = 12 + index * 16
            let tag = u32(bytes, record)
            let offset = Int(u32(bytes, record + 8)), length = Int(u32(bytes, record + 12))
            guard offset <= bytes.count, length <= bytes.count - offset else { return nil }
            var table = Array(bytes[offset..<(offset + length)])
            if tag == 0x6e616d65 { // name
                guard let renamed = rename(table, identity: identity) else { return nil }
                table = renamed
                replacedName = true
            } else if tag == 0x68656164 { // head: checksumAdjustment is computed last.
                guard table.count >= 12 else { return nil }
                put32(0, into: &table, at: 8)
            } else if tag == 0x44534947 { // DSIG describes the unmodified font bytes.
                continue
            }
            tables.append((tag, table))
        }
        guard replacedName else { return nil }
        let n = tables.count
        var output = Array(bytes.prefix(12))
        put16(UInt16(n), into: &output, at: 4)
        var power = 1, selector = 0
        while power * 2 <= n { power *= 2; selector += 1 }
        put16(UInt16(power * 16), into: &output, at: 6)
        put16(UInt16(selector), into: &output, at: 8)
        put16(UInt16(n * 16 - power * 16), into: &output, at: 10)
        output += Array(repeating: 0, count: n * 16)
        var headOffset: Int?
        for (index, table) in tables.enumerated() {
            let offset = output.count, record = 12 + index * 16
            put32(table.tag, into: &output, at: record)
            put32(checksum(table.bytes), into: &output, at: record + 4)
            put32(UInt32(offset), into: &output, at: record + 8)
            put32(UInt32(table.bytes.count), into: &output, at: record + 12)
            if table.tag == 0x68656164 { headOffset = offset }
            output += table.bytes
            while output.count % 4 != 0 { output.append(0) }
        }
        guard let headOffset else { return nil }
        put32(0xb1b0afba &- checksum(output), into: &output, at: headOffset + 8)
        return Data(output)
    }

    private static func rename(_ table: [UInt8], identity: String) -> [UInt8]? {
        guard table.count >= 6, u16(table, 0) <= 1 else { return nil }
        let count = Int(u16(table, 2)), storage = Int(u16(table, 4))
        guard count <= (table.count - 6) / 12, storage <= table.count else { return nil }
        let ids: Set<UInt16> = [1, 3, 4, 6, 16, 21, 25]
        var records: [[UInt8]] = [], strings: [UInt8] = []
        for index in 0..<count {
            let start = 6 + index * 12
            var record = Array(table[start..<(start + 12)])
            let offset = Int(u16(record, 10)), length = Int(u16(record, 8))
            guard offset <= table.count - storage, length <= table.count - storage - offset else { return nil }
            var text = Array(table[(storage + offset)..<(storage + offset + length)])
            if ids.contains(u16(record, 6)) {
                text = [0, 3].contains(u16(record, 0))
                    ? identity.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
                    : Array(identity.utf8)
            }
            // Format 1 language tags address the old string pool. The private
            // names are language-independent; retain other strings with a
            // standard language ID rather than dangling language-tag offsets.
            if u16(record, 4) >= 0x8000 { put16(0, into: &record, at: 4) }
            guard strings.count + text.count <= Int(UInt16.max) else { return nil }
            put16(UInt16(text.count), into: &record, at: 8)
            put16(UInt16(strings.count), into: &record, at: 10)
            records.append(record)
            strings += text
        }
        guard records.contains(where: { u16($0, 6) == 6 }), 6 + count * 12 <= Int(UInt16.max) else { return nil }
        var result: [UInt8] = Array(repeating: 0, count: 6)
        put16(UInt16(count), into: &result, at: 2)
        put16(UInt16(6 + count * 12), into: &result, at: 4)
        return result + records.flatMap { $0 } + strings
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) << 16 | UInt32(u16(bytes, offset + 2))
    }
    private static func put16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255)
    }
    private static func put32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        put16(UInt16(value >> 16), into: &bytes, at: offset)
        put16(UInt16(value & 65535), into: &bytes, at: offset + 2)
    }
    private static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var padded = bytes
        while padded.count % 4 != 0 { padded.append(0) }
        return stride(from: 0, to: padded.count, by: 4).reduce(0) { $0 &+ u32(padded, $1) }
    }
}
