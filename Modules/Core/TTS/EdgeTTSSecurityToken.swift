import Foundation

/// The `Sec-MS-GEC` v2 token the Edge Read Aloud endpoint requires since October 2026.
///
/// The service started refusing the v1 token (a plain SHA-256 of the time window and the
/// client token) with HTTP 403. v2 is `<CS64>-<SHA256*>`: SHA256* is SHA-256 resumed from a
/// fixed mid-block state rather than the standard initial one, and CS64 is a 64-bit keyed
/// hash of the same input seeded from that digest. Ported from rany2/edge-tts `drm.py`
/// ("feat: support Sec-MS-GEC v2 tokens", 2026-10-13); `EdgeTTSTests` pins the output to
/// vectors produced by that implementation.
enum EdgeTTSSecurityToken {
    /// The token for the five-minute window holding `date`.
    static func token(date: Date, trustedClientToken: String) -> String {
        let seconds = Int64(floor(date.timeIntervalSince1970)) + 11_644_473_600
        let ticks = (seconds - seconds % 300) * 10_000_000
        let data = Array("\(ticks)\(trustedClientToken)".utf8)
        let digest = sha256Digest(data)
        let (low, high) = cs64Digest(data, digest: digest)
        let cs64 = (littleEndianBytes(low) + littleEndianBytes(high))
        return hex(cs64) + "-" + hex(digest)
    }

    // MARK: - SHA256*

    private static let initialState: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    /// The working registers after the first 14 rounds of the first block.
    private static let midBlockState: [UInt32] = [
        0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, 0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
    ]
    /// Message-schedule words 16...29 of the first block, before their input-dependent terms.
    private static let midBlockSchedule: [UInt32] = [
        0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, 0xA622EE8C, 0xD1DD9491, 0xC0DD25A0,
        0xF9E70AB6, 0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33, 0xD258B060, 0x72766564,
    ]
    private static let roundConstants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
    ]
    /// Replaces round constant 14 in the first block.
    private static let roundAdjustment: UInt32 = 0xC9DC06A7
    private static let sigma0Adjustment: UInt32 = 0x059C0B80
    private static let sigma1Adjustment: UInt32 = 0x000B92C0

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    private static func sigma0(_ x: UInt32) -> UInt32 { rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3) }
    private static func sigma1(_ x: UInt32) -> UInt32 { rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10) }

    private static func expandSchedule(_ words: inout [UInt32], from first: Int) {
        for index in first..<64 {
            words.append(sigma1(words[index - 2]) &+ words[index - 7] &+ sigma0(words[index - 15]) &+ words[index - 16])
        }
    }

    private static func rounds(_ state: [UInt32], _ words: [UInt32], from first: Int, constants: [UInt32]) -> [UInt32] {
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for index in first..<64 {
            let t1 = h &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ (g ^ (e & (f ^ g))) &+ constants[index] &+ words[index]
            let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) | (c & (a | b)))
            (a, b, c, d, e, f, g, h) = (t1 &+ t2, a, b, c, d &+ t1, e, f, g)
        }
        return [a, b, c, d, e, f, g, h]
    }

    /// The state after the first block, whose first 7 bytes are the input's first 7.
    private static func firstBlockState(_ prefix: ArraySlice<UInt8>) -> [UInt32] {
        let bytes = Array(prefix)
        var words = [UInt32](repeating: 0, count: 14)
        words.append(UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2]))
        words.append(bigEndianWord(bytes, at: 3))
        for index in 16..<30 {
            var value = midBlockSchedule[index - 16]
            if index - 2 >= 14 {
                value &+= index == 16 ? sigma1(words[index - 2]) ^ sigma1Adjustment : sigma1(words[index - 2])
            }
            if index - 7 >= 14 { value &+= words[index - 7] }
            if index - 15 >= 14 {
                value &+= index == 29 ? sigma0(words[index - 15]) ^ sigma0Adjustment : sigma0(words[index - 15])
            }
            words.append(value)
        }
        words.append(sigma1(words[28]) &+ words[23] &+ sigma0(words[15]) &+ words[14]
            &+ roundAdjustment &- roundConstants[14])
        expandSchedule(&words, from: 31)
        var constants = roundConstants
        constants[14] = roundAdjustment
        let working = rounds(midBlockState, words, from: 14, constants: constants)
        return zip(initialState, working).map { $0 &+ $1 }
    }

    private static func sha256Digest(_ data: [UInt8]) -> [UInt8] {
        // The input is the 18-digit tick count plus the client token, always well past 7 bytes.
        precondition(data.count >= 7, "Sec-MS-GEC input must be at least seven bytes")
        let length = 57 + data.count
        var padded = Array(data[7...]) + [0x80]
        padded += [UInt8](repeating: 0, count: ((55 - length) % 64 + 64) % 64)
        padded += (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(length * 8) >> (UInt64($0) * 8)) }
        var state = firstBlockState(data[0..<7])
        for offset in stride(from: 0, to: padded.count, by: 64) {
            var words = (0..<16).map { bigEndianWord(padded, at: offset + $0 * 4) }
            expandSchedule(&words, from: 16)
            let working = rounds(state, words, from: 0, constants: roundConstants)
            state = zip(state, working).map { $0 &+ $1 }
        }
        return state.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> (UInt32($0) * 8)) } }
    }

    // MARK: - CS64

    private static let cs64Coefficients: [(UInt32, UInt32)] = [
        (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D), (0x3BEB65BC, 0x29514038),
        (0xC89C5933, 0xB328CBDF), (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C),
        (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB), (0x06064CF3, 0xFA51A3DA),
        (0xDA79FA60, 0x207CC464), (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
        (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167),
    ]

    private static func rol16(_ x: UInt32) -> UInt32 { (x << 16) | (x >> 16) }

    private static func cs64Digest(_ data: [UInt8], digest: [UInt8]) -> (UInt32, UInt32) {
        let keyA = littleEndianWord(digest, at: 0) | 1
        let keyB = littleEndianWord(digest, at: 4) | 1
        let factors = [keyA &* 0x82893933, keyB &* 0x82893933]
        var terms = cs64Coefficients.enumerated().map { $0.element.0 &* factors[$0.offset % 2] }
        var offsets = cs64Coefficients.map(\.1)

        var input = [UInt8(0)] + data
        input += [UInt8](repeating: 0, count: (4 - input.count % 4) % 4)
        var words = stride(from: 0, to: input.count, by: 4).map { littleEndianWord(input, at: $0) }
        if words.count % 2 == 1 { words.append(0) }
        for (index, word) in words.enumerated() {
            let even = index % 2 == 0
            var term = word &* (even ? keyA : keyB)
            var offset = rol16(word) &* (even ? 0xEF0569FB : 0xC31713DB)
            if index == 0 {
                term &+= 0xF2F90B1A &* factors[0]
                offset &+= 0x0B1A0000
            }
            terms.append(term)
            offsets.append(offset)
        }

        var swapAccumulator: UInt32 = 0
        var swapLast: UInt32 = 0
        var state: UInt32 = 0
        var accumulator: UInt32 = 0
        for index in stride(from: 0, to: terms.count, by: 2) {
            let x = terms[index]
            let y = terms[index + 1]
            var q = rol16(offsets[index] &+ x) &* 0x76F50F34
            swapAccumulator &+= rol16(q) &* 0xC3EFEA97 &+ q
            q = rol16(offsets[index + 1] &+ y) &* 0x1881CE3C
            swapLast = rol16(q) &* 0x35BD1EC9 &+ q
            swapAccumulator &+= swapLast

            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98B111
            state = rol16(state) &* 0x87085B9F
            state = rol16(state) &* 0x12CEB96D
            state = rol16(state) &* 0x257E1D83
            accumulator &+= state
            var t = state &* keyB &+ y
            t = rol16(t) &* 0xA27416F5
            t = rol16(t) &* 0xD38396FF
            state = rol16(rol16(t) &* 0x7C932B89) &* 0xBFA49F69
            accumulator &+= state
        }
        return (swapLast ^ state, swapAccumulator ^ accumulator)
    }

    // MARK: - Bytes

    private static func bigEndianWord(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func littleEndianWord(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }

    private static func littleEndianBytes(_ word: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: word >> (UInt32($0) * 8)) }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
