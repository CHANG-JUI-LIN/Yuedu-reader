import Foundation

struct LegadoRuntimeCapability: Hashable {
    let path: String
    let kind: Kind

    enum Kind: Hashable {
        case namespace
        case constructor
        case method
        case constant
    }
}

enum LegadoRuntimeCapabilityRegistry {
    static let capabilities: Set<LegadoRuntimeCapability> = [
        .init(path: "Packages", kind: .namespace),
        .init(path: "Packages.java.lang", kind: .namespace),
        .init(path: "Packages.java.lang.String", kind: .constructor),
        .init(path: "Packages.java.lang.Integer.parseInt", kind: .method),
        .init(path: "Packages.java.lang.Thread", kind: .namespace),
        .init(path: "Packages.java.lang.Thread.sleep", kind: .method),
        .init(path: "Packages.java.security.MessageDigest.getInstance", kind: .method),
        .init(path: "Packages.java.nio.charset.Charset.forName", kind: .method),
        .init(path: "Packages.java.nio.charset.Charset.defaultCharset", kind: .method),
        .init(path: "Packages.java.nio.charset.StandardCharsets", kind: .constant),
        .init(path: "Packages.java.net.URLEncoder.encode", kind: .method),
        .init(path: "Packages.java.net.URLDecoder.decode", kind: .method),
        .init(path: "Packages.android.text.TextUtils.isEmpty", kind: .method),
        .init(path: "Packages.android.text.TextUtils.equals", kind: .method),
        .init(path: "Packages.io.legado.app.help.http.StrResponse", kind: .constructor),
        .init(path: "Packages.io.legado.app.model.analyzeRule.AnalyzeRule", kind: .constructor),
        // Same objects as the global `org.jsoup` polyfill (JSCoreEngine): Rhino scripts reach
        // jsoup by either name.
        .init(path: "Packages.org.jsoup", kind: .namespace),
        .init(path: "Packages.java.lang.System.nanoTime", kind: .method),
        .init(path: "Packages.java.lang.System.currentTimeMillis", kind: .method),
        .init(path: "Packages.java.util", kind: .namespace),
        .init(path: "Packages.java.util.HashMap", kind: .constructor),
        .init(path: "Packages.java.util.LinkedHashMap", kind: .constructor),
        .init(path: "Packages.java.util.TreeMap", kind: .constructor),
        .init(path: "Packages.java.util.Hashtable", kind: .constructor),
        .init(path: "Packages.java.util.Properties", kind: .constructor),
        .init(path: "Packages.java.util.ArrayList", kind: .constructor),
        .init(path: "Packages.java.util.LinkedList", kind: .constructor),
        .init(path: "Packages.java.util.Vector", kind: .constructor),
        .init(path: "Packages.java.util.Arrays.copyOfRange", kind: .method),
        .init(path: "Packages.java.util.Base64", kind: .namespace),
        .init(path: "Packages.java.util.UUID.randomUUID", kind: .method),
        .init(path: "Packages.android.util.Base64", kind: .namespace),
        .init(path: "Packages.android.util.Base64.DEFAULT", kind: .constant),
        .init(path: "Packages.android.util.Base64.NO_PADDING", kind: .constant),
        .init(path: "Packages.android.util.Base64.NO_WRAP", kind: .constant),
        .init(path: "Packages.android.util.Base64.CRLF", kind: .constant),
        .init(path: "Packages.android.util.Base64.URL_SAFE", kind: .constant),
        .init(path: "Packages.android.util.Base64.encodeToString", kind: .method),
        .init(path: "Packages.android.util.Base64.decode", kind: .method),
        .init(path: "Packages.javax.crypto.Cipher", kind: .namespace),
        .init(path: "Packages.javax.crypto.Cipher.getInstance", kind: .method),
        .init(path: "Packages.javax.crypto.spec.SecretKeySpec", kind: .constructor),
        .init(path: "Packages.javax.crypto.spec.IvParameterSpec", kind: .constructor),
        .init(path: "Packages.cn.hutool.crypto.digest.DigestUtil.md5Hex", kind: .method),
        .init(path: "Packages.cn.hutool.core.util.StrUtil.reverse", kind: .method),
        .init(path: "Packages.cn.hutool.core.util.ZipUtil.gzip", kind: .method),
        .init(path: "Packages.cn.hutool.core.codec.Base64.encode", kind: .method),
        .init(path: "Packages.cn.hutool.core.codec.Base64.decode", kind: .method),
        .init(path: "Packages.okhttp3", kind: .namespace),
        .init(path: "Packages.okhttp3.MediaType.parse", kind: .method),
        .init(path: "Packages.okhttp3.RequestBody.create", kind: .method),
        .init(path: "Packages.okhttp3.Request.Builder", kind: .constructor),
        .init(path: "Packages.okhttp3.OkHttpClient", kind: .constructor),
        .init(path: "Packages.okhttp3.HttpUrl", kind: .namespace),
        .init(path: "Packages.okhttp3.Headers", kind: .namespace),
        // java.io / java.util.zip / java.net / java.security, written in
        // `LegadoJavaInteropRuntime.ioScript`.
        .init(path: "Packages.java.lang.StringBuilder", kind: .constructor),
        .init(path: "Packages.java.lang.StringBuffer", kind: .constructor),
        .init(path: "Packages.java.lang.Byte", kind: .namespace),
        .init(path: "Packages.java.lang.reflect.Array", kind: .namespace),
        .init(path: "Packages.java.io.ByteArrayInputStream", kind: .constructor),
        .init(path: "Packages.java.io.ByteArrayOutputStream", kind: .constructor),
        .init(path: "Packages.java.io.DataOutputStream", kind: .constructor),
        .init(path: "Packages.java.io.BufferedOutputStream", kind: .constructor),
        .init(path: "Packages.java.io.InputStreamReader", kind: .constructor),
        .init(path: "Packages.java.io.StringReader", kind: .constructor),
        .init(path: "Packages.java.io.BufferedReader", kind: .constructor),
        .init(path: "Packages.java.io.OutputStreamWriter", kind: .constructor),
        .init(path: "Packages.java.io.BufferedWriter", kind: .constructor),
        .init(path: "Packages.java.util.zip.Inflater", kind: .constructor),
        .init(path: "Packages.java.util.zip.InflaterInputStream", kind: .constructor),
        .init(path: "Packages.java.util.zip.GZIPInputStream", kind: .constructor),
        .init(path: "Packages.java.util.zip.GZIPOutputStream", kind: .constructor),
        .init(path: "Packages.java.nio.ByteBuffer", kind: .namespace),
        .init(path: "Packages.java.math.BigInteger", kind: .constructor),
        .init(path: "Packages.java.security.SecureRandom", kind: .constructor),
        .init(path: "Packages.java.security.KeyFactory", kind: .namespace),
        .init(path: "Packages.java.security.Signature", kind: .namespace),
        .init(path: "Packages.java.security.spec.X509EncodedKeySpec", kind: .constructor),
        .init(path: "Packages.java.security.spec.PKCS8EncodedKeySpec", kind: .constructor),
        .init(path: "Packages.java.net.URL", kind: .constructor),
        .init(path: "Packages.java.net.HttpURLConnection", kind: .namespace),
        .init(path: "Packages.java.net.Socket", kind: .constructor),
        .init(path: "Packages.java.net.InetSocketAddress", kind: .constructor),
        .init(path: "Packages.javax.net.ssl.HttpsURLConnection", kind: .namespace),
        .init(path: "Packages.javax.crypto.Mac", kind: .namespace),
        .init(path: "Packages.javax.crypto.spec.GCMParameterSpec", kind: .constructor),
        .init(path: "Packages.javax.crypto.spec.DESKeySpec", kind: .constructor),
        .init(path: "Packages.javax.crypto.SecretKeyFactory", kind: .namespace),
        .init(path: "Packages.javax.crypto.SecretKeyFactory.getInstance", kind: .method),
        .init(path: "Packages.android.webkit.CookieManager", kind: .namespace),
        .init(path: "Packages.io.legado.app.help.http.CookieStore", kind: .namespace),
        .init(path: "Packages.cn.hutool.crypto.digest.DigestUtil.md5", kind: .method),
        .init(path: "Packages.cn.hutool.crypto.digest.DigestUtil.sha256Hex", kind: .method),
        .init(path: "Packages.cn.hutool.crypto.digest.DigestUtil.sha1Hex", kind: .method),
        .init(path: "Packages.cn.hutool.core.util.HexUtil", kind: .namespace),
    ]

    static func contains(_ path: String) -> Bool {
        capabilities.contains { $0.path == path }
    }
}
