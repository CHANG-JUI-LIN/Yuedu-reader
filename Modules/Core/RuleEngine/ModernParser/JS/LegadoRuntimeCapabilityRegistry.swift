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
        .init(path: "Packages.java.lang.Thread", kind: .namespace),
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
    ]

    static func contains(_ path: String) -> Bool {
        capabilities.contains { $0.path == path }
    }
}
