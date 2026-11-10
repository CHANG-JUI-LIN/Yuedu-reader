import Foundation
import Testing
@testable import yuedu_app

/// hutool's `SymmetricCrypto` over `javax.crypto.Cipher`, as Legado's scripts reach it. The
/// CTR/CFB/OFB/CBC vectors are LibreSSL's `openssl enc` with the same key and IV; the GCM one
/// is Test Case 2 of the GCM specification (McGrew & Viega).
@Suite("Legado symmetric cipher")
struct LegadoSymmetricCipherTests {
    private let key = Array("1234567890abcdef".utf8)
    private let iv = Array("abcdef1234567890".utf8)
    private let text = Array("hello yuedu ctr!x".utf8)

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    @Test("CTR, CFB, CFB8 and OFB read a partial last block as Java does", arguments: [
        ("AES/CTR/NoPadding", "eb202b8c57d8feea4057770186637c23da"),
        ("AES/CFB/NoPadding", "eb202b8c57d8feea4057770186637c23ef"),
        ("AES/OFB/NoPadding", "eb202b8c57d8feea4057770186637c23ae"),
        ("AES/CFB8/NoPadding", "eb0022fc7dd4dbe5b3249e08793367e036"),
    ])
    func streamModes(transformation: String, expected: String) throws {
        let sealed = try LegadoSymmetricCipher.crypt(
            encrypt: true, transformation: transformation, key: key, iv: iv, data: text
        )
        #expect(hex(sealed) == expected)
        let opened = try LegadoSymmetricCipher.crypt(
            encrypt: false, transformation: transformation, key: key, iv: iv, data: sealed
        )
        #expect(opened == text)
    }

    @Test("ZeroPadding pads to a block and drops the trailing zeros, as hutool does")
    func zeroPadding() throws {
        let sealed = try LegadoSymmetricCipher.crypt(
            encrypt: true, transformation: "AES/CBC/ZeroPadding", key: key, iv: iv, data: Array("abc".utf8)
        )
        #expect(hex(sealed) == "9a9adf14d32896ec9ede1748b96477d5")
        let opened = try LegadoSymmetricCipher.crypt(
            encrypt: false, transformation: "AES/CBC/ZeroPadding", key: key, iv: iv, data: sealed
        )
        #expect(opened == Array("abc".utf8))
    }

    @Test("GCM writes the tag after the ciphertext")
    func gcm() throws {
        let zeroKey = [UInt8](repeating: 0, count: 16)
        let nonce = [UInt8](repeating: 0, count: 12)
        let sealed = try LegadoSymmetricCipher.crypt(
            encrypt: true, transformation: "AES/GCM/NoPadding", key: zeroKey, iv: nonce,
            data: [UInt8](repeating: 0, count: 16)
        )
        #expect(hex(sealed) == "0388dace60b6a392f328c2b971b2fe78" + "ab6e47d42cec13bdf53a67b21257bddf")
        let opened = try LegadoSymmetricCipher.crypt(
            encrypt: false, transformation: "AES/GCM/NoPadding", key: zeroKey, iv: nonce, data: sealed
        )
        #expect(opened == [UInt8](repeating: 0, count: 16))
        #expect(throws: (any Error).self) {
            try LegadoSymmetricCipher.crypt(
                encrypt: false, transformation: "AES/GCM/NoPadding", key: zeroKey, iv: nonce,
                data: Array(sealed.dropLast()) + [0]
            )
        }
    }

    @Test("a DES key is its first 8 bytes, as DESKeySpec reads it")
    func desKeyTruncation() throws {
        let sealed = try LegadoSymmetricCipher.crypt(
            encrypt: true, transformation: "DES/CBC/PKCS5Padding", key: Array("12345678abc".utf8),
            iv: Array("87654321".utf8), data: Array("yuedu".utf8)
        )
        #expect(hex(sealed) == "4c2da0dcdaaac901")
    }

    @Test("java.createSymmetricCrypto reaches the CTR and ZeroPadding transformations")
    func throughTheScript() {
        let engine = JSCoreEngine()
        #expect(engine.evaluate("""
        java.createSymmetricCrypto('AES/CTR/NoPadding', '1234567890abcdef', 'abcdef1234567890')
            .encryptHex('hello yuedu ctr!x')
        """) == "eb202b8c57d8feea4057770186637c23da")
        #expect(engine.evaluate("""
        var c = java.createSymmetricCrypto('AES/CBC/ZeroPadding', '1234567890abcdef', 'abcdef1234567890');
        c.decryptStr(c.encryptHex('abc'));
        """) == "abc")
        #expect(engine.lastError == nil)
    }
}
