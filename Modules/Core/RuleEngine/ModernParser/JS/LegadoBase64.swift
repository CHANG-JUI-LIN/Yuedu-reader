import Foundation

/// The two Base64 decoders Legado's scripts reach (legado-E, MD3 and upstream agree):
/// `java.base64DecodeToByteArray` and a `data:` URL go through `android.util.Base64.decode(…,
/// DEFAULT)` (`EncoderUtils`, `AnalyzeUrl.getByteArrayIfDataUri`); `java.base64Decode(str)` goes
/// through hutool's `Base64.decodeStr`. Neither asks for the `=` padding, and both pass over a
/// character outside the alphabet — a line break, a `\` a page escaped `/` with. Foundation's
/// `Data(base64Encoded:)` refuses unpadded text even with `.ignoreUnknownCharacters`: 雨鹿小说
/// (YCK1329) sends every chapter title as AES text whose padding its server strips, and each
/// one decoded to nothing.
enum LegadoBase64 {
    private static let skip: Int8 = -1
    private static let equals: Int8 = -2

    /// `android.util.Base64.DECODE`: an alphabet character's value, `=` as `equals`, every other
    /// byte (non-ASCII ones included) `skip`.
    private static let androidTable: [Int8] = table(urlSafeAlso: false)
    /// hutool's `Base64Decoder.DECODE_TABLE`: both alphabets — `-` and `_` too.
    private static let hutoolTable: [Int8] = table(urlSafeAlso: true)

    private static func table(urlSafeAlso: Bool) -> [Int8] {
        var table = [Int8](repeating: skip, count: 256)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (value, byte) in alphabet.enumerated() { table[Int(byte)] = Int8(value) }
        if urlSafeAlso {
            table[Int(UInt8(ascii: "-"))] = 62
            table[Int(UInt8(ascii: "_"))] = 63
        }
        table[Int(UInt8(ascii: "="))] = equals
        return table
    }

    /// `android.util.Base64.decode(text, Base64.DEFAULT)`; nil where it throws "bad base-64": a
    /// `=` before the second character of a quantum, anything but skipped bytes after the
    /// padding, or one character left over at the end.
    static func androidDecode(_ text: String) -> Data? {
        var output = Data()
        output.reserveCapacity(text.utf8.count * 3 / 4)
        var state = 0
        var value = 0
        for byte in text.utf8 {
            let d = androidTable[Int(byte)]
            switch state {
            case 0:
                if d >= 0 { value = Int(d); state = 1 } else if d != skip { return nil }
            case 1:
                if d >= 0 { value = value << 6 | Int(d); state = 2 } else if d != skip { return nil }
            case 2:
                if d >= 0 {
                    value = value << 6 | Int(d); state = 3
                } else if d == equals {
                    output.append(UInt8(truncatingIfNeeded: value >> 4)); state = 4
                } else if d != skip { return nil }
            case 3:
                if d >= 0 {
                    value = value << 6 | Int(d)
                    output.append(UInt8(truncatingIfNeeded: value >> 16))
                    output.append(UInt8(truncatingIfNeeded: value >> 8))
                    output.append(UInt8(truncatingIfNeeded: value))
                    state = 0
                } else if d == equals {
                    output.append(UInt8(truncatingIfNeeded: value >> 10))
                    output.append(UInt8(truncatingIfNeeded: value >> 2))
                    state = 5
                } else if d != skip { return nil }
            case 4:
                if d == equals { state = 5 } else if d != skip { return nil }
            default:
                if d != skip { return nil }
            }
        }
        switch state {
        case 1, 4:
            return nil
        case 2:
            output.append(UInt8(truncatingIfNeeded: value >> 4))
        case 3:
            output.append(UInt8(truncatingIfNeeded: value >> 10))
            output.append(UInt8(truncatingIfNeeded: value >> 2))
        default:
            break
        }
        return output
    }

    /// hutool's `Base64Decoder.decode`: never throws. Each quantum takes the next four alphabet
    /// characters, skipping everything else (`=` included); the end of the text pads it.
    static func hutoolDecode(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var output = Data()
        output.reserveCapacity(bytes.count * 3 / 4)
        var index = 0
        func next() -> Int? {
            while index < bytes.count {
                let d = hutoolTable[Int(bytes[index])]
                index += 1
                if d >= 0 { return Int(d) }
            }
            return nil
        }
        while index < bytes.count {
            guard let s0 = next() else { break }
            guard let s1 = next() else { break }
            output.append(UInt8(truncatingIfNeeded: s0 << 2 | s1 >> 4))
            guard let s2 = next() else { break }
            output.append(UInt8(truncatingIfNeeded: (s1 & 0xF) << 4 | s2 >> 2))
            guard let s3 = next() else { break }
            output.append(UInt8(truncatingIfNeeded: (s2 & 3) << 6 | s3))
        }
        return output
    }
}
