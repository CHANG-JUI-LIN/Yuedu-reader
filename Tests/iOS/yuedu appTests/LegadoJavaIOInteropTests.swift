import Foundation
import Testing

@testable import yuedu_app

/// The java.io / java.util.zip / java.net / java.security classes Legado sources call under
/// Rhino (`LegadoJavaInteropRuntime.ioScript`). Every expected value was produced outside the
/// app: zlib/gzip/HMAC by Python's standard library, the RSA key and its SHA256withRSA
/// signature by `openssl`, the AES-GCM vector is test case 2 of the GCM specification.
@Suite("Legado Java IO interop", .serialized)
struct LegadoJavaIOInteropTests {
    private static let hexHelper = """
    function hex(h){var o=[];for(var i=0;i<h.length;i+=2)o.push(parseInt(h.substr(i,2),16));return o;}
    function toHex(b){return b.map(function(v){v=v&255;return (v<16?'0':'')+v.toString(16);}).join('');}
    """

    /// "第一章 七猫的正文\r\nline2\nline3" — 38 bytes of UTF-8.
    private static let raw = "7bbe66cd931d0dcf572f5078b2a3f979cfeae7b35a9ead5dfc6c5a3b2f574e665eaa1198340600"
    private static let zlib = "789c7bbe66cd931d0dcf572f5078b2a3f979cfeae7b35a9ead5dfc6c5a3b2f574e665eaa1198340600da3b14ff"
    private static let gzip = "1f8b08000000000002ff7bbe66cd931d0dcf572f5078b2a3f979cfeae7b35a9ead5dfc6c5a3b2f574e665eaa1198340600370d103e26000000"

    @Test("Inflater, InflaterInputStream and GZIPInputStream read what zlib wrote")
    func inflateStreams() {
        let engine = JSCoreEngine()
        let value = engine.evaluate(Self.hexHelper + """
        var raw=hex('\(Self.raw)');
        // 七猫: a raw-deflate entry inflated into a buffer of its stored size.
        var inf=new Packages.java.util.zip.Inflater(true);
        inf.setInput(raw,0,raw.length);
        var out=Packages.java.util.Arrays.copyOf(raw,38);
        var n=inf.inflate(out);
        var done=inf.finished();
        inf.end();
        var a=String(new Packages.java.lang.String(out,0,n,'UTF-8'));
        // 微信读书: InflaterInputStream drained through a ByteBuffer-backed buffer.
        var s=new Packages.java.util.zip.InflaterInputStream(new Packages.java.io.ByteArrayInputStream(hex('\(Self.zlib)')));
        var bo=new Packages.java.io.ByteArrayOutputStream();
        var buf=Packages.java.nio.ByteBuffer.allocate(8).array(), c;
        while((c=s.read(buf))!=-1) bo.write(buf,0,c);
        // 番茄: GZIPInputStream read line by line.
        var rd=new Packages.java.io.BufferedReader(new Packages.java.io.InputStreamReader(
            new Packages.java.util.zip.GZIPInputStream(new Packages.java.io.ByteArrayInputStream(hex('\(Self.gzip)'))),'UTF-8'));
        var lines=[],line;
        while((line=rd.readLine())!=null) lines.push(line);
        [n, done, a===bo.toString('UTF-8'), lines.join('|')].join('#');
        """)
        #expect(engine.lastError == nil)
        #expect(value == "38#true#true#第一章 七猫的正文|line2|line3")
    }

    @Test("GZIPOutputStream round-trips, and a stream that is not gzip throws Java's error")
    func gzipOutput() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var bos=new Packages.java.io.ByteArrayOutputStream();
        var g=new Packages.java.util.zip.GZIPOutputStream(bos);
        var b=new Packages.java.lang.String('番茄 gzip 請求').getBytes('UTF-8');
        g.write(b,0,b.length);
        g.close();
        var arr=bos.toByteArray();
        var back=new Packages.java.io.BufferedReader(new Packages.java.io.InputStreamReader(
            new Packages.java.util.zip.GZIPInputStream(new Packages.java.io.ByteArrayInputStream(arr)),'UTF-8')).readLine();
        var error='';
        try { new Packages.java.util.zip.GZIPInputStream(new Packages.java.io.ByteArrayInputStream([1,2,3])).read(); }
        catch (e) { error=String(e); }
        [arr[0], arr[1], back, error.indexOf('Not in GZIP format')>=0].join('|');
        """)
        // `toByteArray` is Java's signed bytes: 0x8b reads -117 (oracle case "GZIPOutputStream
        // header via toByteArray", java-byte-sign.json).
        #expect(value == "31|-117|番茄 gzip 請求|true")
    }

    @Test("HttpURLConnection posts its output stream's bytes and reads the reply")
    func httpURLConnection() throws {
        let engine = JSCoreEngine()
        let requests = RequestLog()
        engine.networkHandler = { request, _ in
            requests.append(request)
            let missing = request.url?.path == "/missing"
            let body = missing ? "找不到" : "第一行\n第二行"
            return LegadoHTTPResult(
                finalURL: request.url!,
                statusCode: missing ? 404 : 200, statusMessage: missing ? "Not Found" : "OK",
                // URLSession hands over a decoded body; the header still says gzip.
                headers: ["Content-Encoding": "gzip", "Content-Length": "9", "X-Reply": "yes"],
                cookies: [:], body: body, data: Data(body.utf8)
            )
        }
        let value = engine.evaluate("""
        var c=new Packages.java.net.URL('https://api.yuedu.test/v1?x=1').openConnection();
        c.setRequestProperty('X-Sign','abc');
        c.setDoOutput(true);
        c.setConnectTimeout(8000);
        var o=c.getOutputStream();
        o.write([31,139,0,255],0,4);
        o.flush(); o.close();
        var code=c.getResponseCode();
        var rd=new Packages.java.io.BufferedReader(new Packages.java.io.InputStreamReader(c.getInputStream(),'UTF-8'));
        var sb=new Packages.java.lang.StringBuilder(), line;
        while((line=rd.readLine())!==null) sb.append(line);
        var c2=new Packages.java.net.URL('https://api.yuedu.test/missing').openConnection();
        var thrown='';
        try { c2.getInputStream(); } catch (e) { thrown=String(e); }
        var err=new Packages.java.io.BufferedReader(new Packages.java.io.InputStreamReader(c2.getErrorStream(),'UTF-8')).readLine();
        [code, c.getRequestMethod(), c.getHeaderField('Content-Encoding'), c.getContentLength(), c.getHeaderField('X-Reply'),
         sb.toString(), c2.getResponseCode(), thrown.indexOf('FileNotFoundException')>=0, err].join('|');
        """)
        #expect(engine.lastError == nil)
        #expect(value == "200|POST||-1|yes|第一行第二行|404|true|找不到")
        let post = try #require(requests.all.first)
        #expect(post.httpMethod == "POST")
        #expect(post.httpBody == Data([31, 139, 0, 255]))
        #expect(post.value(forHTTPHeaderField: "X-Sign") == "abc")
        #expect(requests.all.count == 2)
    }

    @Test("okhttp HttpUrl and Headers build the request a source sends")
    func okHttpUrlAndHeaders() throws {
        let engine = JSCoreEngine()
        let requests = RequestLog()
        engine.networkHandler = { request, _ in
            requests.append(request)
            return .bodyOnly(request: request, body: "{\"code\":1}")
        }
        let value = engine.evaluate("""
        var url=Packages.okhttp3.HttpUrl.parse('https://h.yuedu.test/api/data/pic').newBuilder()
            .addQueryParameter('page', 2).addQueryParameter('cid', '中').build();
        var headers=new Packages.okhttp3.Headers.Builder().add('Referer','https://h.yuedu.test/').build();
        var request=new Packages.okhttp3.Request.Builder().url(url).headers(headers).build();
        new Packages.okhttp3.OkHttpClient().newCall(request).execute().body().string();
        """)
        #expect(value == "{\"code\":1}")
        let request = try #require(requests.all.first)
        #expect(request.url?.absoluteString == "https://h.yuedu.test/api/data/pic?page=2&cid=%E4%B8%AD")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://h.yuedu.test/")
    }

    @Test("BigInteger follows Java: radix parsing, modPow, two's-complement bytes")
    func bigInteger() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var B=Packages.java.math.BigInteger;
        var P=new B('ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd1',16);
        var pub=B.valueOf(2).modPow(new B('123456789123456789'),P);
        var r=new B(256,new Packages.java.security.SecureRandom());
        r=r.mod(P.subtract(B.ONE));
        [pub.toString(), pub.toString(16), r.signum()>=0 && r.compareTo(P)<0, new B('-129').toByteArray().join(','),
         new B([255,127]).toString(), B.ONE.negate().mod(B.valueOf(7)).toString(), B.valueOf(3).modInverse(B.valueOf(7)).toString()].join('|');
        """)
        #expect(engine.lastError == nil)
        #expect(value == [
            "1753393094996610171728565939503379729108318094084409252377",
            "4782472fee0f9d1b7c0a1bfb41f2332614e9dce7f12dda19",
            // Oracle case "BigInteger -129 toByteArray" (java-byte-sign.json).
            "true", "-1,127", "-129", "6", "5",
        ].joined(separator: "|"))
    }

    @Test("Mac, AES-GCM and SHA256withRSA give the reference bytes")
    func macGcmSignature() {
        let engine = JSCoreEngine()
        let value = engine.evaluate(Self.hexHelper + """
        var S=Packages.java.lang.String;
        var mac=Packages.javax.crypto.Mac.getInstance('HmacSHA256');
        mac.init(new Packages.javax.crypto.spec.SecretKeySpec(new S('key').getBytes('UTF-8'),'HmacSHA256'));
        var h=toHex(mac.doFinal(new S('The quick brown fox jumps over the lazy dog').getBytes('UTF-8')));

        var C=Packages.javax.crypto.Cipher;
        var zeros=function(n){var o=[];for(var i=0;i<n;i++)o.push(0);return o;};
        var key=new Packages.javax.crypto.spec.SecretKeySpec(zeros(16),'AES');
        var spec=new Packages.javax.crypto.spec.GCMParameterSpec(128,zeros(12));
        var enc=C.getInstance('AES/GCM/NoPadding'); enc.init(C.ENCRYPT_MODE,key,spec);
        var sealed=enc.doFinal(zeros(16));
        var dec=C.getInstance('AES/GCM/NoPadding'); dec.init(C.DECRYPT_MODE,key,spec);
        var opened=toHex(dec.doFinal(sealed));
        sealed[0]^=1;
        var tampered='';
        try { dec.init(C.DECRYPT_MODE,key,spec); dec.doFinal(sealed); } catch (e) { tampered=String(e); }

        var KF=Packages.java.security.KeyFactory.getInstance('RSA');
        var B64=Packages.android.util.Base64;
        var priv=KF.generatePrivate(new Packages.java.security.spec.PKCS8EncodedKeySpec(B64.decode('\(Self.privateKey)',0)));
        var pub=KF.generatePublic(new Packages.java.security.spec.X509EncodedKeySpec(B64.decode('\(Self.publicKey)',0)));
        var sig=Packages.java.security.Signature.getInstance('SHA256WithRSA');
        sig.initSign(priv); sig.update(new S('yuedu-sign').getBytes('UTF-8'));
        var signature=sig.sign();
        var check=Packages.java.security.Signature.getInstance('SHA256withRSA');
        check.initVerify(pub); check.update(new S('yuedu-sign').getBytes('UTF-8'));

        var rsa=C.getInstance('RSA'); rsa.init(1,pub);
        var encryptBlock=rsa.getBlockSize();
        var secret=rsa.doFinal(new S('yuedu').getBytes('UTF-8'));
        var back=C.getInstance('RSA/ECB/PKCS1Padding'); back.init(2,priv);
        [h, toHex(sealed.slice(0,1).map(function(v){return v^1;}))+toHex(sealed.slice(1)), opened, tampered.indexOf('AEADBadTagException')>=0,
         toHex(signature), check.verify(signature), encryptBlock, back.getBlockSize(), String(new S(back.doFinal(secret),'UTF-8'))].join('|');
        """)
        #expect(value == [
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
            "0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf",
            "00000000000000000000000000000000",
            "true",
            Self.signature,
            "true", "117", "128", "yuedu",
        ].joined(separator: "|"))
    }

    @Test("StringBuilder, System, reflect.Array and Socket answer as the JVM does")
    func langAndSocket() {
        let engine = JSCoreEngine()
        let value = engine.evaluate("""
        var sb=new Packages.java.lang.StringBuilder('ab').append('c').append(1).append(null).insert(0,'x');
        var len=sb.length();
        sb.setLength(5);
        var reversed=sb.reverse().toString();
        var dest=Packages.java.lang.reflect.Array.newInstance(Packages.java.lang.Byte.TYPE, 4);
        Packages.java.lang.System.arraycopy([9,8,7],1,dest,2,2);
        var props=Packages.java.lang.System.getProperties();
        var ran=false;
        props.compute('yuedu.lock', function (k, previous) { ran = previous === null; return previous; });
        Packages.java.lang.System.gc();
        var refused='';
        try { new Packages.java.net.Socket().connect(new Packages.java.net.InetSocketAddress('127.0.0.1', 1), 2000); }
        catch (e) { refused=String(e); }
        [len, reversed, dest.join(','), ran, refused.indexOf('java.net.ConnectException')>=0].join('|');
        """)
        #expect(engine.lastError == nil)
        #expect(value == "9|1cbax|0,0,8,7|true|true")
    }

    // An openssl-generated 1024-bit key: PKCS#8 private, X.509 public, and openssl's
    // SHA256withRSA signature of "yuedu-sign".
    private static let privateKey = "MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBANBsjucx08FFKIAGZi+HFr9Uh+pl0RqbkBYWcz5HEsrlnXKjE22lr0Qvxbbv/aH1tgEvELoTzEaSv1WlOfMv+g18GRz/vgwswXWdmiMK4X9K9qoLUt1LZoYpT7rFI8uybeksG/rRj0Jf3Tu8Afk22HQco4/rVmX1haK4tmse+B/nAgMBAAECgYAyq8HOSVne6e5fua6MLX6FQ4rLnLdKjblo9UpNQMA73bj6jtUBWj+TBz49LHlwL6lw/j1Fz9xg5/pmWwYMroRO5IXVRa/Li5o9ZDzVLW7xX79uhlMlehlwA1mLWg8eKIFhalGJMcP3OwnPeB39qSCatP4gSnoDeKegsRdUwsqxeQJBAPH5smnM1pA31fXTXiuhCX2phL1NEjX8f/79WIJVYrumzeu8MCmSRjXd6iuLheFHog9QtToQSbxMy30PElABGOMCQQDcgQtg84T2HbthPMrousR0zk5kicXsDu/V0KU0IRrVt/0Ioze/ilAZdqRkblL07sz7M9Lj4YOKngbkogfwmkAtAkEAySWngTmtFz/DFdG6E4yPhi130aESxVv7zq0teVKfe5xiy1aptrUItlieA8q85ROWDSMrM3Q8x1ITSgdQUr9GvwJAOX5sORtFz+ZwtSnkvkn0b4BbcFt7/9DlOBru+GipVpBiqZ3lK0wlFn6Y3pbline5esZIdqKWac5KfdLBvzp5AQJBAIOj93uYYcTWO/zn33J1MSH7uc5BSBQrsqB6lcLoic2T4lEyiJYurTjPT5FO1l3zp2aaeY1jLXdl9G8xOpSoIDc="
    private static let publicKey = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDQbI7nMdPBRSiABmYvhxa/VIfqZdEam5AWFnM+RxLK5Z1yoxNtpa9EL8W27/2h9bYBLxC6E8xGkr9VpTnzL/oNfBkc/74MLMF1nZojCuF/SvaqC1LdS2aGKU+6xSPLsm3pLBv60Y9CX907vAH5Nth0HKOP61Zl9YWiuLZrHvgf5wIDAQAB"
    private static let signature = "9454e6811cf6f421b42c73f6bf57c4050ab74e018d7c45d6dced628bd185dc72512fcfccca5130b562c5196c43b271c4bbdd89b3bdf80220b82f02036751801f73f78e58da8030ad6717f18f95a140b6b13fcc0a1170adc79f4f9aa5857cf59df788aeb3ad5932727b6b2a7ef92402d4eac4317aae58c1a29f72a4070632a693"
}

/// The requests a stubbed transport saw, from whichever thread the bridge ran on.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    var all: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}
