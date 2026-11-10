import CommonCrypto
import CryptoKit
import Foundation

/// The `javax.crypto.Cipher` a Legado script reaches through hutool's `SymmetricCrypto`
/// (`java.createSymmetricCrypto`, legado-E's `SymmetricCryptoAndroid`, and the deprecated
/// `java.aes*` helpers built on it): a transformation `ALGORITHM/MODE/PADDING`, a key and an
/// optional IV.
///
/// Until 11-07 only ECB and CBC with PKCS5/NoPadding were read; every other transformation
/// answered "" and the source's chapter, title or request signature came out empty (YCK1330
/// #31 and YCK1331 #1/#90 use CTR, GCM and ZeroPadding).
enum LegadoSymmetricCipher {
    enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case badParameter(String)
        case cryptFailed(Int32)

        var description: String {
            switch self {
            case .unsupported(let what): "unsupported \(what)"
            case .badParameter(let what): what
            case .cryptFailed(let status): "CommonCrypto status \(status)"
            }
        }
    }

    private enum Mode {
        case ecb, cbc, cfb, cfb8, ofb, ctr, gcm
    }

    private enum Padding {
        case pkcs7, none
    }

    /// One transformation as `Cipher.getInstance` reads it, with hutool's `ZeroPadding`:
    /// `SymmetricCrypto.init` swaps it for `NoPadding` and pads and unpads the data itself.
    private struct Spec {
        let algorithm: CCAlgorithm
        let blockSize: Int
        let isDES: Bool
        let isTripleDES: Bool
        let mode: Mode
        let padding: Padding
        let zeroPadding: Bool

        init(_ transformation: String) throws {
            let parts = transformation.uppercased().split(separator: "/").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            switch parts.first ?? "AES" {
            case "AES":
                algorithm = CCAlgorithm(kCCAlgorithmAES); blockSize = kCCBlockSizeAES128
                isDES = false; isTripleDES = false
            case "DES":
                algorithm = CCAlgorithm(kCCAlgorithmDES); blockSize = kCCBlockSizeDES
                isDES = true; isTripleDES = false
            // 书山聚合 ships chapter content as DES/CBC/PKCS5Padding; hutool covers the DES
            // family as well as AES.
            case "DESEDE", "3DES", "TRIPLEDES":
                algorithm = CCAlgorithm(kCCAlgorithm3DES); blockSize = kCCBlockSize3DES
                isDES = false; isTripleDES = true
            default:
                throw Failure.unsupported("algorithm in \(transformation)")
            }
            // `Cipher.getInstance("AES")` is AES/ECB/PKCS5Padding.
            let modeName = parts.count > 1 ? parts[1] : "ECB"
            switch modeName {
            case "ECB": mode = .ecb
            case "CBC": mode = .cbc
            // Java's bare CFB/OFB feed back a whole block, as CommonCrypto's do.
            case "CFB": mode = .cfb
            case "CFB128" where blockSize == 16: mode = .cfb
            case "CFB64" where blockSize == 8: mode = .cfb
            case "CFB8": mode = .cfb8
            case "OFB": mode = .ofb
            case "OFB128" where blockSize == 16: mode = .ofb
            case "OFB64" where blockSize == 8: mode = .ofb
            case "CTR": mode = .ctr
            case "GCM" where blockSize == kCCBlockSizeAES128: mode = .gcm
            default: throw Failure.unsupported("mode in \(transformation)")
            }
            let paddingName = parts.count > 2 ? parts[2] : "PKCS5PADDING"
            switch paddingName {
            case "PKCS5PADDING", "PKCS7PADDING": padding = .pkcs7; zeroPadding = false
            case "NOPADDING": padding = .none; zeroPadding = false
            case "ZEROPADDING": padding = .none; zeroPadding = true
            default: throw Failure.unsupported("padding in \(transformation)")
            }
        }
    }

    static func crypt(
        encrypt: Bool, transformation: String, key rawKey: [UInt8], iv: [UInt8], data: [UInt8]
    ) throws -> [UInt8] {
        let spec = try Spec(transformation)
        let key = try cipherKey(rawKey, spec: spec)
        // hutool's `paddingDataWithZero`: zeros up to a whole block, none when it already is.
        var input = data
        if encrypt, spec.zeroPadding, input.count % spec.blockSize != 0 {
            input += [UInt8](repeating: 0, count: spec.blockSize - input.count % spec.blockSize)
        }
        var output: [UInt8]
        if spec.mode == .gcm {
            output = try gcm(encrypt: encrypt, key: key, iv: iv, aad: [], data: input)
        } else {
            output = try commonCrypto(encrypt: encrypt, spec: spec, key: key, iv: iv, data: input)
        }
        // hutool's `removePadding`: a whole number of blocks loses its trailing zeros.
        if !encrypt, spec.zeroPadding, output.count % spec.blockSize == 0 {
            while output.last == 0 { output.removeLast() }
        }
        return output
    }

    /// hutool's `KeyUtil.generateKey`: a DES key is `DESKeySpec(key)` — its first 8 bytes —
    /// and a DESede key `DESedeKeySpec(key)`, its first 24; an AES key is used as given.
    private static func cipherKey(_ key: [UInt8], spec: Spec) throws -> [UInt8] {
        if spec.isDES {
            guard key.count >= 8 else { throw Failure.badParameter("DES key is \(key.count) bytes") }
            return Array(key.prefix(8))
        }
        if spec.isTripleDES {
            guard key.count >= 24 else { throw Failure.badParameter("DESede key is \(key.count) bytes") }
            return Array(key.prefix(24))
        }
        guard [16, 24, 32].contains(key.count) else {
            throw Failure.badParameter("AES key is \(key.count) bytes")
        }
        return key
    }

    private static func commonCrypto(
        encrypt: Bool, spec: Spec, key: [UInt8], iv: [UInt8], data: [UInt8]
    ) throws -> [UInt8] {
        let mode: CCMode
        switch spec.mode {
        case .ecb: mode = CCMode(kCCModeECB)
        case .cbc: mode = CCMode(kCCModeCBC)
        case .cfb: mode = CCMode(kCCModeCFB)
        case .cfb8: mode = CCMode(kCCModeCFB8)
        case .ofb: mode = CCMode(kCCModeOFB)
        case .ctr: mode = CCMode(kCCModeCTR)
        case .gcm: throw Failure.unsupported("GCM through CommonCrypto")
        }
        // CommonCrypto pads ECB and CBC itself; a feedback or counter mode with PKCS5Padding
        // (which Java accepts) is padded here.
        let blockModes = spec.mode == .ecb || spec.mode == .cbc
        var input = data
        if encrypt, spec.padding == .pkcs7, !blockModes {
            let count = spec.blockSize - input.count % spec.blockSize
            input += [UInt8](repeating: UInt8(count), count: count)
        }
        let ivBytes: [UInt8]?
        switch spec.mode {
        case .ecb:
            ivBytes = nil
        case .cbc:
            // As before 11-07: a CBC IV of the wrong length is a zero block.
            ivBytes = iv.count == spec.blockSize ? iv : [UInt8](repeating: 0, count: spec.blockSize)
        default:
            guard iv.count == spec.blockSize else {
                throw Failure.badParameter("IV is \(iv.count) bytes, not \(spec.blockSize)")
            }
            ivBytes = iv
        }
        var cryptor: CCCryptorRef?
        // CTR counts big-endian over the whole block, as Java's does (the only order
        // CommonCrypto has; `kCCModeOptionCTR_BE` is deprecated for that reason).
        var status = CCCryptorCreateWithMode(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), mode, spec.algorithm,
            CCPadding(blockModes && spec.padding == .pkcs7 ? ccPKCS7Padding : ccNoPadding),
            ivBytes, key, key.count, nil, 0, 0, 0, &cryptor
        )
        guard status == kCCSuccess, let cryptor else { throw Failure.cryptFailed(status) }
        defer { CCCryptorRelease(cryptor) }
        // At least one byte, so the buffer has an address for `CCCryptorFinal` to write after.
        var output = [UInt8](
            repeating: 0, count: max(1, CCCryptorGetOutputLength(cryptor, input.count, true))
        )
        var moved = 0
        status = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw Failure.cryptFailed(status) }
        var finalMoved = 0
        status = output.withUnsafeMutableBufferPointer { buffer in
            CCCryptorFinal(cryptor, buffer.baseAddress! + moved, buffer.count - moved, &finalMoved)
        }
        guard status == kCCSuccess else { throw Failure.cryptFailed(status) }
        output.removeSubrange((moved + finalMoved)...)
        if !encrypt, spec.padding == .pkcs7, !blockModes {
            guard let count = output.last.map(Int.init), (1...spec.blockSize).contains(count),
                  count <= output.count,
                  output.suffix(count).allSatisfy({ Int($0) == count })
            else { throw Failure.badParameter("bad PKCS5 padding") }
            output.removeLast(count)
        }
        return output
    }

    /// `AES/GCM/NoPadding`: the ciphertext with a 128-bit tag after it, as Java writes and reads
    /// it — Java's default tag, the one `IvParameterSpec` gets on Android (hutool's `setIv`),
    /// and the only one CryptoKit seals with. `aad` is `Cipher.updateAAD`'s.
    static func gcm(encrypt: Bool, key: [UInt8], iv: [UInt8], aad: [UInt8], data: [UInt8]) throws -> [UInt8] {
        let symmetricKey = SymmetricKey(data: key)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: iv)
        } catch {
            throw Failure.badParameter("GCM IV is \(iv.count) bytes")
        }
        if encrypt {
            let sealed = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce, authenticating: aad)
            return Array(sealed.ciphertext) + Array(sealed.tag)
        }
        let tagSize = 16
        guard data.count >= tagSize else { throw Failure.badParameter("GCM data shorter than its tag") }
        let box = try AES.GCM.SealedBox(
            nonce: nonce, ciphertext: data.dropLast(tagSize), tag: data.suffix(tagSize)
        )
        return Array(try AES.GCM.open(box, using: symmetricKey, authenticating: aad))
    }
}
