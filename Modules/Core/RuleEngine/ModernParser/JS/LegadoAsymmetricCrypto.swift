import Foundation
import Security

/// RSA for Legado's `java.createAsymmetricCrypto(transformation)` (hutool `AsymmetricCrypto`,
/// legado-E `help/crypto/AsymmetricCrypto.kt`). The JS object lives in
/// `LegadoJavaInteropRuntime`; this does the arithmetic through `SecKey`.
///
/// What hutool does and this matches:
/// - Keys are Java's encodings: X.509 `SubjectPublicKeyInfo` for a public key, PKCS#8 for a
///   private one. A bare PKCS#1 key is accepted too. `SecKey` wants PKCS#1, so the wrapper
///   is unwrapped first.
/// - Either key may encrypt or decrypt. Decrypting with the public key — reading what a server
///   encrypted with its private key, as 乐读小说's chapters are — is the default.
/// - The input is cut into blocks: the modulus length to decrypt, eleven bytes less to encrypt.
enum LegadoAsymmetricCrypto {
    enum Failure: Error, CustomStringConvertible {
        case unsupported(String)
        case badKey(String)
        case operation(String)

        var description: String {
            switch self {
            case .unsupported(let what): "unsupported \(what)"
            case .badKey(let why): "bad key: \(why)"
            case .operation(let why): why
            }
        }
    }

    /// - Parameters:
    ///   - transformation: `RSA`, `RSA/ECB/PKCS1Padding` or `RSA/ECB/NoPadding`.
    ///   - key: the DER key bytes, public or private as `usePublicKey` says.
    static func crypt(
        transformation: String,
        key: [UInt8],
        usePublicKey: Bool,
        encrypt: Bool,
        data: [UInt8]
    ) throws -> [UInt8] {
        let parts = transformation.uppercased().split(separator: "/").map(String.init)
        guard parts.first == "RSA" else { throw Failure.unsupported("algorithm \(transformation)") }
        let padding = parts.count > 2 ? parts[2] : "PKCS1PADDING"
        let padded: Bool
        switch padding {
        case "PKCS1PADDING": padded = true
        case "NOPADDING": padded = false
        default: throw Failure.unsupported("padding \(transformation)")
        }

        let secKey = try makeKey(der: key, isPublic: usePublicKey)
        let blockSize = SecKeyGetBlockSize(secKey)
        guard blockSize > 11 else { throw Failure.badKey("block size \(blockSize)") }
        let chunk = encrypt ? (padded ? blockSize - 11 : blockSize) : blockSize
        var output: [UInt8] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let block = Array(data[offset..<end])
            output += try cryptBlock(
                block, key: secKey, blockSize: blockSize, usePublicKey: usePublicKey,
                encrypt: encrypt, padded: padded
            )
            offset = end
        }
        return output
    }

    private static func cryptBlock(
        _ block: [UInt8], key: SecKey, blockSize: Int, usePublicKey: Bool, encrypt: Bool, padded: Bool
    ) throws -> [UInt8] {
        switch (usePublicKey, encrypt) {
        case (true, true):
            // The usual direction: SecKey pads (type 2) itself.
            return try apply(padded ? .rsaEncryptionPKCS1 : .rsaEncryptionRaw, key: key,
                             to: padded ? block : leftPadded(block, to: blockSize), encrypt: true)
        case (false, false):
            return try apply(padded ? .rsaEncryptionPKCS1 : .rsaEncryptionRaw, key: key,
                             to: block, encrypt: false)
        case (true, false):
            // m = c^e mod n: the raw public operation, then the padding the private key's
            // holder put on.
            let raw = leftPadded(try apply(.rsaEncryptionRaw, key: key, to: leftPadded(block, to: blockSize), encrypt: true), to: blockSize)
            return padded ? unpadded(raw) : raw
        case (false, true):
            // c = m^d mod n over a type-1 block: what Java's private-key encryption produces.
            let input = padded ? try typeOnePadded(block, to: blockSize) : leftPadded(block, to: blockSize)
            return leftPadded(try apply(.rsaEncryptionRaw, key: key, to: input, encrypt: false), to: blockSize)
        }
    }

    private static func apply(
        _ algorithm: SecKeyAlgorithm, key: SecKey, to block: [UInt8], encrypt: Bool
    ) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        let result = encrypt
            ? SecKeyCreateEncryptedData(key, algorithm, Data(block) as CFData, &error)
            : SecKeyCreateDecryptedData(key, algorithm, Data(block) as CFData, &error)
        guard let result else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw Failure.operation("RSA \(encrypt ? "encrypt" : "decrypt") failed: \(reason)")
        }
        return [UInt8](result as Data)
    }

    private static func leftPadded(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        bytes.count >= length ? bytes : [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }

    private static func typeOnePadded(_ block: [UInt8], to length: Int) throws -> [UInt8] {
        guard block.count <= length - 11 else { throw Failure.operation("RSA block too long") }
        return [0x00, 0x01] + [UInt8](repeating: 0xFF, count: length - 3 - block.count) + [0x00] + block
    }

    /// PKCS#1 v1.5: `00 01 FF… 00 data` (a private key's) or `00 02 random… 00 data`. A block
    /// without that header is returned as it is: Android's `Cipher.getInstance("RSA")` — which
    /// the sources were written against — is not reliably the padded variant, and a block that
    /// was never padded cannot start with a valid header by accident in practice.
    private static func unpadded(_ block: [UInt8]) -> [UInt8] {
        guard block.count > 11, block[0] == 0x00, block[1] == 0x01 || block[1] == 0x02,
              let separator = block[2...].firstIndex(of: 0x00), separator >= 10 else {
            return block
        }
        return Array(block[(separator + 1)...])
    }

    /// The modulus length in bytes, from which Java's `Cipher.getBlockSize()` is computed.
    static func modulusBytes(der: [UInt8], isPublic: Bool) throws -> Int {
        SecKeyGetBlockSize(try makeKey(der: der, isPublic: isPublic))
    }

    /// `java.security.Signature` (`SHA256withRSA` and the rest of the PKCS#1 v1.5 family)
    /// over the whole message, with a PKCS#8 (or PKCS#1) private key.
    static func sign(algorithm: String, privateKey der: [UInt8], message: [UInt8]) throws -> [UInt8] {
        let key = try makeKey(der: der, isPublic: false)
        let secAlgorithm = try signatureAlgorithm(algorithm)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, secAlgorithm, Data(message) as CFData, &error) else {
            throw Failure.operation(error?.takeRetainedValue().localizedDescription ?? "sign failed")
        }
        return [UInt8](signature as Data)
    }

    static func verify(algorithm: String, publicKey der: [UInt8], message: [UInt8], signature: [UInt8]) throws -> Bool {
        let key = try makeKey(der: der, isPublic: true)
        let secAlgorithm = try signatureAlgorithm(algorithm)
        return SecKeyVerifySignature(key, secAlgorithm, Data(message) as CFData, Data(signature) as CFData, nil)
    }

    private static func signatureAlgorithm(_ name: String) throws -> SecKeyAlgorithm {
        switch name.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA1WITHRSA": return .rsaSignatureMessagePKCS1v15SHA1
        case "SHA224WITHRSA": return .rsaSignatureMessagePKCS1v15SHA224
        case "SHA256WITHRSA": return .rsaSignatureMessagePKCS1v15SHA256
        case "SHA384WITHRSA": return .rsaSignatureMessagePKCS1v15SHA384
        case "SHA512WITHRSA": return .rsaSignatureMessagePKCS1v15SHA512
        default: throw Failure.unsupported("signature \(name)")
        }
    }

    // MARK: Keys

    private static func makeKey(der: [UInt8], isPublic: Bool) throws -> SecKey {
        guard !der.isEmpty else { throw Failure.badKey("no \(isPublic ? "public" : "private") key set") }
        let pkcs1 = try isPublic ? publicPKCS1(der) : privatePKCS1(der)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw Failure.badKey(reason)
        }
        return key
    }

    /// `SubjectPublicKeyInfo ::= SEQUENCE { AlgorithmIdentifier, BIT STRING }` → the BIT
    /// STRING's PKCS#1 key; a PKCS#1 key (`SEQUENCE { INTEGER n, INTEGER e }`) as it is.
    private static func publicPKCS1(_ der: [UInt8]) throws -> [UInt8] {
        let children = try DER.children(ofSequence: der)
        if children.count == 2, children[0].tag == 0x30, children[1].tag == 0x03 {
            let bits = children[1].content
            guard let unusedBits = bits.first, unusedBits == 0 else {
                throw Failure.badKey("public key BIT STRING")
            }
            return Array(bits.dropFirst())
        }
        return der
    }

    /// `PrivateKeyInfo ::= SEQUENCE { INTEGER, AlgorithmIdentifier, OCTET STRING }` → the
    /// OCTET STRING's PKCS#1 key; a PKCS#1 key as it is.
    private static func privatePKCS1(_ der: [UInt8]) throws -> [UInt8] {
        let children = try DER.children(ofSequence: der)
        if children.count >= 3, children[0].tag == 0x02, children[1].tag == 0x30, children[2].tag == 0x04 {
            return children[2].content
        }
        return der
    }

    /// Just enough DER to unwrap a key.
    private enum DER {
        struct Element {
            let tag: UInt8
            let content: [UInt8]
        }

        static func children(ofSequence der: [UInt8]) throws -> [Element] {
            var index = 0
            let outer = try element(in: der, at: &index)
            guard outer.tag == 0x30 else { throw Failure.badKey("not a DER SEQUENCE") }
            var children: [Element] = []
            var inner = 0
            while inner < outer.content.count {
                children.append(try element(in: outer.content, at: &inner))
            }
            return children
        }

        private static func element(in bytes: [UInt8], at index: inout Int) throws -> Element {
            guard index + 2 <= bytes.count else { throw Failure.badKey("truncated DER") }
            let tag = bytes[index]
            var length = Int(bytes[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, index + count <= bytes.count else {
                    throw Failure.badKey("DER length")
                }
                length = bytes[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard length >= 0, index + length <= bytes.count else { throw Failure.badKey("truncated DER") }
            let content = Array(bytes[index..<(index + length)])
            index += length
            return Element(tag: tag, content: content)
        }
    }
}
