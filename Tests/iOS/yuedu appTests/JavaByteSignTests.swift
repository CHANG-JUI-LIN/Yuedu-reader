import Foundation
import Testing
@testable import yuedu_app

/// A Java `byte[]` reaches a Legado script as Rhino hands it over: every element −128…127.
/// Every expected value below is the oracle's (`lc.py oracle
/// scripts/legado-compat/oracle/cases/java-byte-sign.json`, Rhino 1.8.1 as legado-E sets it
/// up); each test names its case.
///
/// 西瓜免费 (YCK1331 #63) Base64-encodes its HMAC-SHA256 sign itself: `b >> 2`, and `^= 192`
/// when `b` is negative. With 0–255 bytes the index ran past its 64-letter alphabet, the sign
/// came out wrong, and the server answered 接口鉴权不合法.
@Suite("Java byte arrays are signed", .serialized)
struct JavaByteSignTests {
    private func evaluate(_ script: String) -> String? {
        let engine = JSCoreEngine()
        let value = engine.evaluate(script)
        #expect(engine.lastError == nil, "\(engine.lastError ?? "")")
        return value
    }

    /// "imported String getBytes is signed"
    @Test func importedStringGetBytes() {
        #expect(evaluate(#"""
            var ji = new JavaImporter(); ji.importPackage(Packages.java.lang); var out;
            with (ji) { var b = String('aé').getBytes('UTF-8'); out = [b.length, b[0], b[1], b[2], typeof b[1]].join(','); }
            out
            """#) == "3,97,-61,-87,number")
    }

    /// "new java.lang.String getBytes is signed"
    @Test func javaStringGetBytes() {
        #expect(evaluate(#"var b = new java.lang.String('ÿ').getBytes('ISO-8859-1'); [b.length, b[0]].join(',')"#) == "1,-1")
    }

    /// "Mac doFinal is signed" — the call 西瓜免费 makes.
    @Test func macDoFinal() {
        #expect(evaluate(#"""
            var ji = new JavaImporter(); ji.importPackage(Packages.java.lang, Packages.javax.crypto, Packages.javax.crypto.spec); var out;
            with (ji) {
                var m = Mac.getInstance('HmacSHA256'); m.init(SecretKeySpec(String('k').getBytes('UTF-8'), 'HmacSHA256'));
                var b = m.doFinal(String('m').getBytes('UTF-8')); var a = [];
                for (var i = 0; i < b.length; i++) a.push(b[i]); out = a.join(',');
            }
            out
            """#) == "-74,0,-112,-29,5,34,-105,-82,-75,-96,-128,-120,-100,-30,-4,75,-54,-107,126,117,111,-82,-76,-33,125,49,-128,12,-95,-25,113,-20")
    }

    /// "MessageDigest digest is signed"
    @Test func messageDigest() {
        #expect(evaluate(#"""
            var b = java.security.MessageDigest.getInstance('MD5').digest(new java.lang.String('m').getBytes('UTF-8'));
            var a = []; for (var i = 0; i < b.length; i++) a.push(b[i]); a.join(',')
            """#) == "111,-113,87,113,80,-112,-38,38,50,69,57,-120,-39,-95,80,27")
    }

    /// "Base64 decoder is signed"
    @Test func base64Decoder() {
        #expect(evaluate(#"var b = java.util.Base64.getDecoder().decode('/4A='); [b.length, b[0], b[1]].join(',')"#) == "2,-1,-128")
    }

    /// "Cipher doFinal is signed"
    @Test func cipherDoFinal() {
        #expect(evaluate(#"""
            var c = javax.crypto.Cipher.getInstance('AES/ECB/PKCS5Padding');
            c.init(javax.crypto.Cipher.ENCRYPT_MODE, new javax.crypto.spec.SecretKeySpec(new java.lang.String('0123456789abcdef').getBytes('UTF-8'), 'AES'));
            var b = c.doFinal(new java.lang.String('m').getBytes('UTF-8'));
            var a = []; for (var i = 0; i < b.length; i++) a.push(b[i]); a.join(',')
            """#) == "-110,42,-10,68,50,84,24,-13,-11,106,33,67,-106,-110,-19,65")
    }

    /// "ByteArrayOutputStream toByteArray is signed"
    @Test func outputStreamToByteArray() {
        #expect(evaluate("var o = new java.io.ByteArrayOutputStream(); o.write(200); o.write(5); var b = o.toByteArray(); [b[0], b[1]].join(',')") == "-56,5")
    }

    /// "ByteArrayInputStream read is unsigned, read(buffer) signed"
    @Test func inputStreamReads() {
        #expect(evaluate(#"""
            var s = new java.io.ByteArrayInputStream(java.util.Base64.getDecoder().decode('/4A='));
            var one = s.read(); var buf = java.lang.reflect.Array.newInstance(java.lang.Byte.TYPE, 1);
            var n = s.read(buf, 0, 1); [one, n, buf[0]].join(',')
            """#) == "255,1,-128")
    }

    /// "ByteBuffer get is signed"
    @Test func byteBufferGet() {
        #expect(evaluate("var bb = java.nio.ByteBuffer.wrap(java.util.Base64.getDecoder().decode('/4A=')); [bb.get(), bb.get(1)].join(',')") == "-1,-128")
    }

    /// "BigInteger toByteArray is signed"
    @Test func bigIntegerToByteArray() {
        #expect(evaluate("var b = new java.math.BigInteger('255').toByteArray(); [b.length, b[0], b[1]].join(',')") == "2,0,-1")
    }

    /// "Arrays copyOfRange keeps the sign"
    @Test func copyOfRange() {
        #expect(evaluate("var b = java.util.Arrays.copyOfRange(java.util.Base64.getDecoder().decode('/4A='), 0, 2); [b[0], b[1]].join(',')") == "-1,-128")
    }

    /// "signed shift lands in the Base64 table" — 西瓜免费's first step on a byte ≥ 0x80.
    @Test func signedShiftIndexesTheAlphabet() {
        #expect(evaluate(#"""
            var ji = new JavaImporter(); ji.importPackage(Packages.java.lang); var out;
            with (ji) { var b10 = String('é').getBytes('UTF-8')[0]; var i19 = b10 >> 2; if ((b10 & -128) !== 0) i19 ^= 192; out = i19 & 255; }
            out
            """#) == "48")
    }

    /// Signed bytes still read back as the same bytes everywhere the runtime takes a byte array.
    @Test func signedBytesReadBackUnchanged() {
        #expect(evaluate(#"""
            var b = new java.lang.String('中文').getBytes('UTF-8');
            [String(new java.lang.String(b, 'UTF-8')), java.bytesToStr(b, 'UTF-8'),
             android.util.Base64.encodeToString(b, 2), java.base64Encode(String(new java.lang.String(b, 'UTF-8')))].join('|')
            """#) == "中文|中文|5Lit5paH|5Lit5paH")
    }
}
