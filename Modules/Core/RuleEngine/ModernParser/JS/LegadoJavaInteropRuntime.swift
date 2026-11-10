import Foundation
import JavaScriptCore

/// Installs the common JVM/Android surface exposed by Legado's Rhino runtime.
/// The JavaScript types are intentionally local and capability-bounded; unknown
/// namespaces may be traversed, but invoking one throws at the call site.
enum LegadoJavaInteropRuntime {
    static func install(
        in context: JSContext,
        registry: LegadoRuntimeCapabilityRegistry.Type = LegadoRuntimeCapabilityRegistry.self
    ) {
        if context.objectForKeyedSubscript("__yueduLegadoInteropInstalled")?.toBool() == true {
            return
        }
        let paths = registry.capabilities.map(\.path).sorted()
        context.setObject(paths, forKeyedSubscript: "__yueduLegadoCapabilities" as NSString)
        context.evaluateScript(script)
    }

    private static let script = #"""
    (function (global) {
        if (global.__yueduLegadoInteropInstalled) return;
        Object.defineProperty(global, '__yueduLegadoInteropInstalled', { value: true });
        // Taken now, before any source script runs: a source's top-level `var Proxy = …` lands
        // on this global (存档书库's header, YCK1331), where Legado's Java objects never see it.
        var NativeProxy = global.Proxy;
        // The bridge's own `strToBytes` (0–255), taken before `java.strToBytes` answers a script
        // with Java's signed bytes (below): `getBytes` here works in 0–255.
        var bridge = global.java, bridgeStrToBytes = bridge && bridge.strToBytes;
        function nativeStrToBytes(s, charset) { return bridgeStrToBytes.call(bridge, s, charset); }

        var capabilityPaths = global.__yueduLegadoCapabilities || [];
        function isEnabled(path) {
            var fullPath = 'Packages.' + path;
            for (var i = 0; i < capabilityPaths.length; i++) {
                if (capabilityPaths[i] === fullPath || capabilityPaths[i].indexOf(fullPath + '.') === 0) return true;
            }
            return false;
        }

        function unsignedBytes(value) {
            if (value == null) return [];
            if (value.__bytes) value = value.__bytes;
            if (typeof value === 'string' || value instanceof String) return getBytes(String(value), 'UTF-8');
            return Array.prototype.slice.call(value).map(function (v) { return Number(v) & 255; });
        }
        // A Java `byte[]` as Rhino hands it to a script: every element −128…127. The runtime
        // works in 0–255 (`unsignedBytes`) and turns its bytes into Java's only where a script
        // receives them — what Java types `byte[]`: `getBytes`, `digest`, `doFinal`, a Base64
        // decoder, `toByteArray`, a filled buffer. Sources do arithmetic that only the signed
        // value answers: 西瓜免费 (YCK1331) Base64-encodes its HMAC itself with `b >> 2` and
        // `^= 192` for a negative `b`, and with 0–255 indexed past its alphabet, so the server
        // rejected the request's sign (接口鉴权不合法). `& 255`, `< 0 ? v + 256` and every
        // consumer here read both alike.
        function javaByte(v) { return (Number(v) << 24) >> 24; }
        function javaBytes(value) { return unsignedBytes(value).map(javaByte); }
        function charsetName(value) {
            return String(value || 'UTF-8').replace(/[_\s]/g, '-').toUpperCase();
        }
        function utf8Bytes(s) {
            var out = [];
            for (var i = 0; i < s.length; i++) {
                var c = s.charCodeAt(i);
                if (c < 0x80) out.push(c);
                else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
                else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
                    var low = s.charCodeAt(++i);
                    var cp = 0x10000 + ((c & 1023) << 10) + (low & 1023);
                    out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
                } else out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
            }
            return out;
        }
        // Android's `new String(bytes)` (ART StringFactory) is the W3C UTF-8 decoder: each
        // maximal subpart of a malformed sequence becomes one U+FFFD. Sources hash such a
        // string — 小小阅读 derives its AES key from `String(random salt bytes)` — so a
        // decoder that read past malformed bytes produced a different key and no plaintext.
        function utf8String(bytes) {
            var out = '', i = 0, n = bytes.length;
            while (i < n) {
                var c = bytes[i++] & 255, need = 0, lower = 0x80, upper = 0xbf, cp;
                if (c < 0x80) { out += String.fromCharCode(c); continue; }
                if (c >= 0xc2 && c <= 0xdf) { need = 1; cp = c & 31; }
                else if (c >= 0xe0 && c <= 0xef) { need = 2; cp = c & 15; if (c === 0xe0) lower = 0xa0; if (c === 0xed) upper = 0x9f; }
                else if (c >= 0xf0 && c <= 0xf4) { need = 3; cp = c & 7; if (c === 0xf0) lower = 0x90; if (c === 0xf4) upper = 0x8f; }
                else { out += '�'; continue; }
                while (need > 0) {
                    var b = i < n ? bytes[i] & 255 : -1;
                    if (b < lower || b > upper) break;
                    cp = (cp << 6) | (b & 63); i++; need--; lower = 0x80; upper = 0xbf;
                }
                if (need > 0) { out += '�'; continue; }
                if (cp < 0x10000) out += String.fromCharCode(cp);
                else { cp -= 0x10000; out += String.fromCharCode(0xd800 | (cp >> 10), 0xdc00 | (cp & 1023)); }
            }
            return out;
        }
        function getBytes(value, charset) {
            var s = String(value), name = charsetName(charset), out = [], i;
            if (name === 'ISO-8859-1' || name === 'ISO8859-1') {
                for (i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 255);
                return out;
            }
            if (name === 'UTF-16LE' || name === 'UTF-16BE') {
                var little = name === 'UTF-16LE';
                for (i = 0; i < s.length; i++) {
                    var c = s.charCodeAt(i), lo = c & 255, hi = c >> 8;
                    out.push(little ? lo : hi, little ? hi : lo);
                }
                return out;
            }
            if (name !== 'UTF-8' && name !== 'UTF8') return unsignedBytes(nativeStrToBytes(s, name));
            return utf8Bytes(s);
        }
        function bytesToString(value, charset, offset, length) {
            var bytes = unsignedBytes(value);
            if (offset != null) bytes = bytes.slice(Number(offset), Number(offset) + Number(length));
            var name = charsetName(charset), out = '', i;
            if (name === 'ISO-8859-1' || name === 'ISO8859-1') {
                for (i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
                return out;
            }
            if (name === 'UTF-16LE' || name === 'UTF-16BE') {
                var little = name === 'UTF-16LE';
                for (i = 0; i + 1 < bytes.length; i += 2) {
                    out += String.fromCharCode(little ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
                }
                return out;
            }
            if (name !== 'UTF-8' && name !== 'UTF8') return String(java.bytesToStr(bytes, name));
            return utf8String(bytes);
        }
        function JavaString(value, a, b, c) {
            var stringValue;
            if (typeof value === 'string' || value instanceof String) stringValue = String(value);
            else if (typeof a === 'number') stringValue = bytesToString(value, c, a, b);
            else stringValue = bytesToString(value, a || 'UTF-8');
            var boxed = new String(stringValue);
            boxed.getBytes = function (charset) { return javaBytes(getBytes(stringValue, charset)); };
            return boxed;
        }
        Object.defineProperty(String.prototype, 'getBytes', {
            value: function (charset) { return javaBytes(getBytes(String(this), charset)); },
            enumerable: false, configurable: true, writable: true
        });

        // From a table, in one pass over the bytes as `unsignedBytes` reads them: 番茄听书
        // (YCK1330) encodes a chapter's audio, up to 22 MB, with `HexUtil.encodeHexStr`, and a
        // copy, a `map` and a `toString(16)` a byte took 3.4 s of the script's 30 (11-09).
        var hexPairs = [];
        for (var pair = 0; pair < 256; pair++) hexPairs.push((pair < 16 ? '0' : '') + pair.toString(16));
        function bytesToHex(bytes) {
            var source = bytes == null ? [] : (bytes.__bytes || bytes);
            if (typeof source === 'string' || source instanceof String) source = getBytes(String(source), 'UTF-8');
            var length = source.length >>> 0, parts = new Array(length);
            for (var i = 0; i < length; i++) parts[i] = hexPairs[Number(source[i]) & 255];
            return parts.join('');
        }
        function hexToBytes(hex) {
            var out = [];
            for (var i = 0; i + 1 < hex.length; i += 2) out.push(parseInt(hex.substr(i, 2), 16));
            return out;
        }
        var STD = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        function encode64(value, flags) {
            var bytes = unsignedBytes(value), url = (flags & 8) !== 0;
            var alphabet = url ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_' : STD;
            var out = '', i = 0;
            for (; i + 2 < bytes.length; i += 3) {
                var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
                out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + alphabet[(n >> 6) & 63] + alphabet[n & 63];
            }
            if (bytes.length - i === 1) {
                var n1 = bytes[i] << 16;
                out += alphabet[(n1 >> 18) & 63] + alphabet[(n1 >> 12) & 63] + (((flags & 1) !== 0) ? '' : '==');
            } else if (bytes.length - i === 2) {
                var n2 = (bytes[i] << 16) | (bytes[i + 1] << 8);
                out += alphabet[(n2 >> 18) & 63] + alphabet[(n2 >> 12) & 63] + alphabet[(n2 >> 6) & 63] + (((flags & 1) !== 0) ? '' : '=');
            }
            if ((flags & 2) === 0 && out.length) {
                var sep = (flags & 4) !== 0 ? '\r\n' : '\n';
                out = out.match(/.{1,76}/g).join(sep) + sep;
            }
            return out;
        }
        function decode64(value) {
            var s = String(value).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/]/g, '');
            var out = [], i = 0;
            while (i < s.length) {
                var remain = s.length - i, e1 = STD.indexOf(s[i]), e2 = STD.indexOf(s[i + 1]);
                var e3 = remain > 2 ? STD.indexOf(s[i + 2]) : -1, e4 = remain > 3 ? STD.indexOf(s[i + 3]) : -1;
                if (e2 >= 0) out.push(((e1 << 2) | (e2 >> 4)) & 255);
                if (e3 >= 0) out.push((((e2 & 15) << 4) | (e3 >> 2)) & 255);
                if (e4 >= 0) out.push((((e3 & 3) << 6) | e4) & 255);
                i += 4;
            }
            return out;
        }
        var AndroidBase64 = {
            DEFAULT: 0, NO_PADDING: 1, NO_WRAP: 2, CRLF: 4, URL_SAFE: 8, NO_CLOSE: 16,
            encodeToString: function (bytes, flags) { return encode64(bytes, Number(flags) || 0); },
            decode: function (value) { return javaBytes(decode64(value)); }
        };
        var JavaBase64 = {
            getDecoder: function () { return { decode: function (value) { return javaBytes(decode64(value)); } }; },
            getEncoder: function () { return { encodeToString: function (bytes) { return encode64(bytes, 2); } }; }
        };
        var UUID = {
            randomUUID: function () {
                var value = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
                    var r = Math.floor(Math.random() * 16), v = c === 'x' ? r : ((r & 3) | 8);
                    return v.toString(16);
                });
                return { toString: function () { return value; }, valueOf: function () { return value; } };
            }
        };
        // Java's `Arrays.copyOfRange`: the range alone is read, and zeros fill what lies past
        // the end. It read the whole array first: 番茄听书 (YCK1330) decrypts a chapter's audio
        // one sample at a time, copying each out of the 8 MB file, and a sample took 34 ms —
        // 42 000 of them, twenty minutes, where a script has 30 s (11-09).
        var Arrays = {
            copyOfRange: function (value, from, to) {
                from = Number(from); to = Number(to);
                var array = value != null && typeof value !== 'string' && !(value instanceof String);
                var part = array
                    ? Array.prototype.slice.call(value.__bytes || value, from, to)
                    : unsignedBytes(value).slice(from, to);
                var out = javaBytes(part);
                while (out.length < to - from) out.push(0);
                return out;
            }
        };
        var System = { nanoTime: function () { return Date.now() * 1000000; }, currentTimeMillis: function () { return Date.now(); } };
        // Java's parseInt rejects what JS parseInt skips over: an empty string, a stray
        // character, an int overflow. A source's `try`/`catch` sees the same exception.
        var Integer = {
            MAX_VALUE: 2147483647, MIN_VALUE: -2147483648,
            parseInt: function (value, radix) {
                var s = String(value), r = radix == null ? 10 : Number(radix);
                var digits = '0123456789abcdefghijklmnopqrstuvwxyz'.slice(0, r);
                var body = /^[+-]/.test(s) ? s.slice(1) : s;
                var valid = r >= 2 && r <= 36 && body.length > 0 && body.toLowerCase().split('').every(function (ch) {
                    return digits.indexOf(ch) >= 0;
                });
                var parsed = valid ? parseInt(s, r) : NaN;
                if (!valid || parsed > 2147483647 || parsed < -2147483648) {
                    throw new Error('java.lang.NumberFormatException: For input string: "' + s + '"' + (r === 10 ? '' : ' under radix ' + r));
                }
                return parsed;
            }
        };
        function SecretKeySpec(bytes, algorithm) { return { __bytes: unsignedBytes(bytes), __alg: String(algorithm || '') }; }
        function IvParameterSpec(bytes) { return { __bytes: unsignedBytes(bytes) }; }
        // javax.crypto.spec.DESKeySpec: the key's first eight bytes; Java refuses fewer.
        // javax.crypto.SecretKeyFactory turns it into the key `Cipher.init` reads — for DES the
        // same bytes (SunJCE fixes the parity bits, which DES ignores). 移动阅读 (YCK1330) signs
        // its requests this way.
        function DESKeySpec(bytes, offset) {
            var all = unsignedBytes(bytes), at = Number(offset) || 0;
            if (all.length - at < 8) throw new Error('java.security.InvalidKeyException: Wrong key size');
            var key = all.slice(at, at + 8);
            return { __bytes: key, __alg: 'DES', getKey: function () { return javaBytes(key); } };
        }
        DESKeySpec.DES_KEY_LEN = 8;
        var SecretKeyFactory = {
            getInstance: function (algorithm) {
                var name = String(algorithm);
                if (!/^DES$/i.test(name)) {
                    throw new Error('java.security.NoSuchAlgorithmException: ' + name + ' SecretKeyFactory not available');
                }
                return {
                    getAlgorithm: function () { return name; },
                    generateSecret: function (spec) {
                        var key = unsignedBytes(spec);
                        return {
                            __bytes: key, __alg: name,
                            getEncoded: function () { return javaBytes(key); },
                            getAlgorithm: function () { return name; },
                            getFormat: function () { return 'RAW'; }
                        };
                    }
                };
            }
        };
        // javax.crypto.Cipher is in `ioScript`, with the RSA and GCM paths it shares.
        // java.security.MessageDigest: bytes in, Java's signed bytes out.
        function MessageDigest(algorithm) { this._alg = algorithm; this._buf = []; }
        MessageDigest.getInstance = function (algorithm) {
            var name = String(algorithm).toUpperCase().replace(/_/g, '-');
            if (!/^(MD5|SHA-?1|SHA-?224|SHA-?256|SHA-?384|SHA-?512)$/.test(name)) {
                throw new Error('java.security.NoSuchAlgorithmException: ' + algorithm + ' MessageDigest not available');
            }
            return new MessageDigest(name);
        };
        MessageDigest.prototype.update = function (input, offset, length) {
            if (typeof input === 'number') { this._buf.push(input & 255); return; }
            var bytes = unsignedBytes(input);
            if (offset != null) bytes = bytes.slice(Number(offset), Number(offset) + Number(length));
            for (var i = 0; i < bytes.length; i++) this._buf.push(bytes[i]);
        };
        MessageDigest.prototype.digest = function (input) {
            if (input != null) this.update(input);
            var out = javaBytes(java.digestBytes(this._buf, this._alg));
            this._buf = [];
            return out;
        };
        MessageDigest.prototype.reset = function () { this._buf = []; };
        MessageDigest.prototype.getAlgorithm = function () { return this._alg; };

        // java.nio.charset.Charset: a name that `new String(bytes, cs)` / `s.getBytes(cs)` read.
        function JavaCharset(name) { this._name = charsetName(name); }
        JavaCharset.prototype.name = JavaCharset.prototype.displayName = JavaCharset.prototype.toString = function () { return this._name; };
        var Charset = {
            forName: function (name) { return new JavaCharset(name); },
            defaultCharset: function () { return new JavaCharset('UTF-8'); }
        };
        var StandardCharsets = {
            UTF_8: new JavaCharset('UTF-8'), ISO_8859_1: new JavaCharset('ISO-8859-1'), US_ASCII: new JavaCharset('US-ASCII'),
            UTF_16: new JavaCharset('UTF-16'), UTF_16BE: new JavaCharset('UTF-16BE'), UTF_16LE: new JavaCharset('UTF-16LE')
        };

        // java.net.URLEncoder / URLDecoder: application/x-www-form-urlencoded in a charset.
        function isUrlSafe(b) {
            return (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b === 46 || b === 45 || b === 42 || b === 95;
        }
        var URLEncoder = {
            encode: function (value, charset) {
                var bytes = getBytes(String(value), charset || 'UTF-8'), out = '';
                for (var i = 0; i < bytes.length; i++) {
                    var b = bytes[i] & 255;
                    if (isUrlSafe(b)) out += String.fromCharCode(b);
                    else if (b === 32) out += '+';
                    else out += '%' + (b < 16 ? '0' : '') + b.toString(16).toUpperCase();
                }
                return out;
            }
        };
        var URLDecoder = {
            decode: function (value, charset) {
                var s = String(value), bytes = [], i = 0;
                while (i < s.length) {
                    var c = s.charAt(i);
                    if (c === '+') { bytes.push(32); i++; }
                    else if (c === '%' && /^[0-9A-Fa-f]{2}$/.test(s.substr(i + 1, 2))) { bytes.push(parseInt(s.substr(i + 1, 2), 16)); i += 3; }
                    else {
                        var cp = s.codePointAt(i), ch = String.fromCodePoint(cp);
                        Array.prototype.push.apply(bytes, getBytes(ch, charset || 'UTF-8'));
                        i += ch.length;
                    }
                }
                return bytesToString(bytes, charset || 'UTF-8');
            }
        };

        // java.lang.Thread: `sleep` blocks the script's thread, as it does under Rhino; sources
        // pace their own requests with it (八叉书库, 兽人小说站, 晋江).
        var JavaThread = { sleep: function (millis) { java.sleepMillis(Number(millis) || 0); } };

        var TextUtils = {
            isEmpty: function (s) { return s == null || String(s).length === 0; },
            equals: function (a, b) { return a === b || (a != null && b != null && String(a) === String(b)); }
        };

        // io.legado.app.model.analyzeRule.AnalyzeRule() — a rule reader of the script's own
        // (`LegadoAnalyzeRule`), callable with or without `new`. Its methods return what
        // Legado's do: `setContent`/`setBaseUrl` the reader, `getElement(s)` jsoup objects.
        function AnalyzeRule() {
            var reader = java.newAnalyzeRule();
            if (reader == null) throw new Error('AnalyzeRule() is unavailable outside a rule parse');
            return new AnalyzeRuleReader(reader);
        }
        function AnalyzeRuleReader(reader) { Object.defineProperty(this, '_r', { value: reader }); }
        function jsoupWrap(v) { return typeof global.__yueduJsoupWrap === 'function' ? global.__yueduJsoupWrap(v) : v; }
        AnalyzeRuleReader.prototype.setContent = function (content, baseUrl) {
            this._r.setContent(content, baseUrl == null ? null : String(baseUrl));
            return this;
        };
        AnalyzeRuleReader.prototype.setBaseUrl = function (baseUrl) {
            this._r.setBaseUrl(baseUrl == null ? null : String(baseUrl));
            return this;
        };
        AnalyzeRuleReader.prototype.getString = function (rule, mContent, isUrl) {
            return this._r.getString(rule, mContent, isUrl === true);
        };
        AnalyzeRuleReader.prototype.getStringList = function (rule, mContent, isUrl) {
            return this._r.getStringList(rule, mContent, isUrl === true);
        };
        AnalyzeRuleReader.prototype.getElement = function (rule) {
            var v = this._r.getElement(String(rule));
            return v === undefined ? null : jsoupWrap(v);
        };
        AnalyzeRuleReader.prototype.getElements = function (rule) { return jsoupWrap(this._r.getElements(String(rule))); };

        // io.legado.app.help.http.StrResponse(url, body) — callable with or without `new`, as a
        // Java class is under Rhino. The (rawResponse, body) form takes the response's URL.
        function StrResponse(url, body) {
            var u = url != null && typeof url.request === 'function' ? url.request().url() : url;
            return java.makeStrResponse(u == null ? '' : String(u), body == null ? '' : String(body));
        }

        // Legado's StrResponse has `val url` and `var body` beside `url()` and `body()`, and
        // Rhino reads either: `String(result.url).replace('/search', '/verified')` in a
        // loginCheckJs, `result.body.match(…)`. Here the exported method is all there is, so
        // `result.url` was the function and its text the method's source. Each becomes a getter
        // whose value can still be called and otherwise reads as the string: String methods,
        // `+`, `==`, String(), JSON. `typeof` says "function" and an empty one is truthy.
        // Under Rhino `result.body` is the Java method, so a check written for either reads
        // it with `typeof b === 'function' ? b.call(result) : b` (台湾小说, YCK1331): `call`
        // and `apply` stay, since String.prototype in place of Function.prototype drops them.
        function callableString(value) {
            var text = value == null ? '' : String(value);
            var read = function () { return text; };
            Object.setPrototypeOf(read, String.prototype);
            var own = function () { return text; };
            Object.defineProperty(read, 'toString', { value: own });
            Object.defineProperty(read, 'valueOf', { value: own });
            Object.defineProperty(read, 'toJSON', { value: own });
            Object.defineProperty(read, 'call', { value: own });
            Object.defineProperty(read, 'apply', { value: own });
            Object.defineProperty(read, 'length', { value: text.length });
            return read;
        }
        (function () {
            if (!global.java || typeof global.java.makeStrResponse !== 'function') return;
            var proto = Object.getPrototypeOf(global.java.makeStrResponse('', ''));
            ['url', 'body'].forEach(function (name) {
                var method = proto[name];
                if (typeof method !== 'function') return;
                Object.defineProperty(proto, name, {
                    configurable: true,
                    get: function () { return callableString(method.call(this)); }
                });
            });
        })();

        // hutool `DigestUtil`: a String is digested as its UTF-8 bytes, a byte array as itself;
        // `md5` / `sha1` / `sha256` answer the digest's bytes, the `…Hex` twins its hex. 起点中文
        // (YCK1331) keys its chapter decryption with `DigestUtil.md5(bytes)`.
        function hutoolDigest(algorithm) {
            return function (data) { return javaBytes(java.digestBytes(unsignedBytes(data), algorithm)); };
        }
        function hutoolDigestHex(algorithm) {
            return function (data) { return bytesToHex(java.digestBytes(unsignedBytes(data), algorithm)); };
        }
        var DigestUtil = {
            md5: hutoolDigest('MD5'), md5Hex: hutoolDigestHex('MD5'),
            sha1: hutoolDigest('SHA-1'), sha1Hex: hutoolDigestHex('SHA-1'),
            sha256: hutoolDigest('SHA-256'), sha256Hex: hutoolDigestHex('SHA-256')
        };
        var StrUtil = { reverse: function (s) { return String(s).split('').reverse().join(''); } };
        var ZipUtil = { gzip: function (value) { return javaBytes(java.gzipBytes(value)); } };
        var HutoolBase64 = { encode: function (s) { return java.base64Encode(String(s)); }, decode: function (s) { return java.base64Decode(String(s)); } };

        function MediaType(value) { this.value = String(value || ''); }
        MediaType.parse = function (value) { return new MediaType(value); };
        var RequestBody = {
            create: function (a, b) {
                var body = a instanceof MediaType ? b : a;
                var mediaType = a instanceof MediaType ? a : b;
                return { body: body == null ? '' : String(body), mediaType: mediaType || null };
            }
        };
        function RequestBuilder() {
            this._url = ''; this._method = 'GET'; this._body = ''; this._headers = {};
        }
        RequestBuilder.prototype.url = function (value) { this._url = String(value || ''); return this; };
        RequestBuilder.prototype.get = function () { this._method = 'GET'; this._body = ''; return this; };
        RequestBuilder.prototype.head = function () { this._method = 'HEAD'; this._body = ''; return this; };
        RequestBuilder.prototype.post = function (value) { this._method = 'POST'; this._body = value || { body: '' }; return this; };
        RequestBuilder.prototype.method = function (method, value) { this._method = String(method || 'GET').toUpperCase(); this._body = value || { body: '' }; return this; };
        RequestBuilder.prototype.addHeader = function (name, value) { this._headers[String(name)] = String(value); return this; };
        RequestBuilder.prototype.header = RequestBuilder.prototype.addHeader;
        RequestBuilder.prototype.build = function () {
            if (this._body && this._body.mediaType && !this._headers['Content-Type']) {
                this._headers['Content-Type'] = String(this._body.mediaType.value || this._body.mediaType);
            }
            return { url: this._url, method: this._method, body: (this._body && this._body.body) || '', headers: this._headers };
        };
        var Request = { Builder: RequestBuilder };
        // okhttp3 `Response`. The bytes are read with the response, so `close()` — which
        // sources call in a `finally` (起点中文, YCK1331) — has nothing left to release.
        function OkHttpResponse(nativeResponse) { this._native = nativeResponse; }
        OkHttpResponse.prototype.body = function () {
            var nativeResponse = this._native;
            return {
                string: function () { return nativeResponse.body(); },
                bytes: function () { return javaBytes(nativeResponse.bodyBytes()); },
                close: function () {}
            };
        };
        OkHttpResponse.prototype.header = function (name) { return this._native.header(String(name)); };
        OkHttpResponse.prototype.close = function () {};
        OkHttpResponse.prototype.headers = function () {
            var nativeHeaders = this._native.headers();
            return {
                names: function () { return nativeHeaders.keySet(); },
                get: function (name) { return nativeHeaders.get(String(name)); }
            };
        };
        OkHttpResponse.prototype.code = function () { return this._native.code(); };
        OkHttpResponse.prototype.message = function () { return this._native.message(); };
        OkHttpResponse.prototype.isSuccessful = function () { return this._native.isSuccessful(); };
        function OkHttpClient() {}
        OkHttpClient.prototype.newCall = function (request) {
            return {
                execute: function () {
                    var response = java.httpExecute(request.method, request.url, request.body, request.headers);
                    return new OkHttpResponse(response);
                }
            };
        };

        java.createSymmetricCrypto = function (transformation, key, iv) {
            var t = String(transformation || 'AES');
            if (t.indexOf('/') < 0) t += '/ECB/PKCS5Padding';
            var keyHex = bytesToHex(key), ivHex = iv == null ? '' : bytesToHex(iv);
            function decryptInputHex(data) {
                if (typeof data !== 'string') return bytesToHex(data);
                var compact = data.replace(/\s+/g, '');
                if (/^[0-9A-Fa-f]+$/.test(compact) && compact.length % 2 === 0) return compact.toLowerCase();
                if (/^[A-Za-z0-9+/_-]+={0,2}$/.test(compact)) return bytesToHex(decode64(compact));
                return bytesToHex(getBytes(data, 'UTF-8'));
            }
            function encryptInputHex(data) {
                return typeof data === 'string'
                    ? bytesToHex(getBytes(data, 'UTF-8'))
                    : bytesToHex(data);
            }
            return {
                decrypt: function (data) { return javaBytes(hexToBytes(java.aesDecryptHex(t, keyHex, ivHex, decryptInputHex(data)))); },
                decryptStr: function (data) { return bytesToString(this.decrypt(data), 'UTF-8'); },
                encrypt: function (data) { return javaBytes(hexToBytes(java.aesEncryptHex(t, keyHex, ivHex, encryptInputHex(data)))); },
                encryptBase64: function (data) { return encode64(this.encrypt(data), 2); },
                encryptHex: function (data) { return java.aesEncryptHex(t, keyHex, ivHex, encryptInputHex(data)); }
            };
        };
        // legado `JsEncodeUtils.createAsymmetricCrypto(transformation)` — hutool's
        // AsymmetricCrypto as legado-E wraps it: keys are DER bytes (X.509 public, PKCS#8
        // private; a Base64 or PEM string is read as its bytes), and every operation takes an
        // optional `usePublicKey` that defaults to true — so a plain `decrypt` uses the public
        // key (乐读小说). Kotlin's `getKeyType(null)` is the private key, and so is `null` here.
        java.createAsymmetricCrypto = function (transformation) {
            var t = String(transformation || 'RSA');
            var keys = { pub: '', priv: '' };
            function keyHex(key) {
                if (typeof key === 'string' || key instanceof String) {
                    return bytesToHex(decode64(String(key).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')));
                }
                return bytesToHex(key);
            }
            function decryptInputHex(data) {
                if (typeof data !== 'string' && !(data instanceof String)) return bytesToHex(data);
                var compact = String(data).replace(/\s+/g, '');
                if (/^[0-9A-Fa-f]+$/.test(compact) && compact.length % 2 === 0) return compact.toLowerCase();
                return bytesToHex(decode64(compact));
            }
            function encryptInputHex(data) {
                return typeof data === 'string' || data instanceof String
                    ? bytesToHex(getBytes(String(data), 'UTF-8'))
                    : bytesToHex(data);
            }
            function usesPublic(usePublicKey) {
                return usePublicKey === undefined || (usePublicKey !== null && !!usePublicKey);
            }
            function run(encrypt, data, usePublicKey) {
                var pub = usesPublic(usePublicKey);
                return java.rsaCryptHex(t, pub ? keys.pub : keys.priv, pub, encrypt,
                    encrypt ? encryptInputHex(data) : decryptInputHex(data));
            }
            var crypto = {
                setPublicKey: function (key) { keys.pub = keyHex(key); return crypto; },
                setPrivateKey: function (key) { keys.priv = keyHex(key); return crypto; },
                decrypt: function (data, usePublicKey) { return javaBytes(hexToBytes(run(false, data, usePublicKey))); },
                decryptStr: function (data, usePublicKey) { return bytesToString(crypto.decrypt(data, usePublicKey), 'UTF-8'); },
                encrypt: function (data, usePublicKey) { return javaBytes(hexToBytes(run(true, data, usePublicKey))); },
                encryptHex: function (data, usePublicKey) { return run(true, data, usePublicKey); },
                encryptBase64: function (data, usePublicKey) { return encode64(crypto.encrypt(data, usePublicKey), 2); }
            };
            return crypto;
        };
        java.aesBase64Decode = function (data, key, transformation, iv) {
            return javaBytes(hexToBytes(java.aesDecryptHex(String(transformation || 'AES'), bytesToHex(getBytes(key || '', 'UTF-8')), bytesToHex(getBytes(iv || '', 'UTF-8')), bytesToHex(decode64(data)))));
        };
        java.aesBase64DecodeToString = function () { return bytesToString(java.aesBase64Decode.apply(java, arguments), 'UTF-8'); };
        // legado `JsEncodeUtils.aes*`: deprecated there but still called — 存档书库 (YCK 1331)
        // signs its archive.org login with aesEncodeToBase64String. Each is
        // createSymmetricCrypto(transformation, key, iv) with string keys read as UTF-8, and the
        // `Args` variants as legado writes them (decode: Base64 key and iv; encode: as given).
        java.aesDecodeToByteArray = function (str, key, transformation, iv) {
            return java.createSymmetricCrypto(transformation, key, iv).decrypt(str);
        };
        java.aesDecodeToString = function (str, key, transformation, iv) {
            return java.createSymmetricCrypto(transformation, key, iv).decryptStr(str);
        };
        java.aesBase64DecodeToByteArray = java.aesDecodeToByteArray;
        java.aesDecodeArgsBase64Str = function (data, key, mode, padding, iv) {
            return java.createSymmetricCrypto('AES/' + mode + '/' + padding, decode64(key), decode64(iv || '')).decryptStr(data);
        };
        java.aesEncodeToByteArray = function (data, key, transformation, iv) {
            return java.createSymmetricCrypto(transformation, key, iv).encrypt(data);
        };
        // Legado's own body: aesEncodeToString decrypts (`decryptStr(data)`), and sources
        // written against it expect that.
        java.aesEncodeToString = java.aesDecodeToString;
        java.aesEncodeToBase64ByteArray = function (data, key, transformation, iv) {
            return javaBytes(getBytes(java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data), 'UTF-8'));
        };
        java.aesEncodeToBase64String = function (data, key, transformation, iv) {
            return java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
        };
        java.aesEncodeArgsBase64Str = function (data, key, mode, padding, iv) {
            return java.createSymmetricCrypto('AES/' + mode + '/' + padding, key, iv).encryptBase64(data);
        };
        // legado `JsEncodeUtils.tripleDES*`: thin wrappers over createSymmetricCrypto("DESede/…").
        // 起点's Argus API signs every request with tripleDESEncodeBase64Str; without it the
        // qm source's 彩蛋 TOC and 彩蛋 content requests never left the device.
        // The `Args` variants take a Base64 key and a UTF-8 iv, as legado's do.
        java.tripleDESEncodeBase64Str = function (data, key, mode, padding, iv) {
            return java.createSymmetricCrypto('DESede/' + mode + '/' + padding, key, iv).encryptBase64(data);
        };
        java.tripleDESDecodeStr = function (data, key, mode, padding, iv) {
            return java.createSymmetricCrypto('DESede/' + mode + '/' + padding, key, iv).decryptStr(data);
        };
        java.tripleDESEncodeArgsBase64Str = function (data, key, mode, padding, iv) {
            return java.createSymmetricCrypto('DESede/' + mode + '/' + padding, decode64(key), getBytes(iv || '', 'UTF-8')).encryptBase64(data);
        };
        java.tripleDESDecodeArgsBase64Str = function (data, key, mode, padding, iv) {
            return java.createSymmetricCrypto('DESede/' + mode + '/' + padding, decode64(key), getBytes(iv || '', 'UTF-8')).decryptStr(data);
        };
        // legado `JsEncodeUtils.des*`: string key and iv (UTF-8), as legado's createSymmetricCrypto
        // takes them. 阅友网络 signs its requests with desEncodeToBase64String.
        java.desDecodeToString = function (data, key, transformation, iv) {
            return java.createSymmetricCrypto(transformation, key, iv).decryptStr(data);
        };
        java.desBase64DecodeToString = java.desDecodeToString;
        java.desEncodeToString = function (data, key, transformation, iv) {
            return bytesToString(java.createSymmetricCrypto(transformation, key, iv).encrypt(data), 'UTF-8');
        };
        java.desEncodeToBase64String = function (data, key, transformation, iv) {
            return java.createSymmetricCrypto(transformation, key, iv).encryptBase64(data);
        };
        java.toURL = function (url, baseUrl) {
            var value = java.urlParts(String(url || ''), baseUrl == null ? null : String(baseUrl));
            value.searchParams = __yueduJavaMap(value.searchParams || {});
            return value;
        };
        // Legado's JsExtensions answer these with a Kotlin `ByteArray`, which reaches a script
        // as Java's signed bytes; the bridge's own answer is 0–255.
        ['strToBytes', 'base64DecodeToByteArray', 'hexDecodeToByteArray'].forEach(function (name) {
            var native = bridge && bridge[name];
            if (typeof native !== 'function') return;
            bridge[name] = function () { return javaBytes(native.apply(bridge, arguments)); };
        });

        \#(ioScript)

        var members = {
            'java.lang': {
                String: JavaString, System: System, Integer: Integer, Thread: JavaThread,
                StringBuilder: StringBuilder, StringBuffer: StringBuilder, Byte: JavaByte
            },
            'java.lang.reflect': { Array: ReflectArray },
            'java.util': { Base64: JavaBase64, Arrays: Arrays, UUID: UUID },
            'java.util.zip': {
                Inflater: Inflater, InflaterInputStream: InflaterInputStream,
                GZIPInputStream: GZIPInputStream, GZIPOutputStream: GZIPOutputStream
            },
            'java.io': {
                ByteArrayInputStream: ByteArrayInputStream, ByteArrayOutputStream: ByteArrayOutputStream,
                DataOutputStream: DataOutputStream, BufferedOutputStream: BufferedOutputStream,
                InputStreamReader: InputStreamReader, StringReader: StringReader, BufferedReader: BufferedReader,
                OutputStreamWriter: OutputStreamWriter, BufferedWriter: BufferedWriter
            },
            'java.nio': { ByteBuffer: ByteBuffer },
            'java.math': { BigInteger: BigInteger },
            'java.security': { MessageDigest: MessageDigest, SecureRandom: SecureRandom, KeyFactory: KeyFactory, Signature: Signature },
            'java.security.spec': { X509EncodedKeySpec: X509EncodedKeySpec, PKCS8EncodedKeySpec: PKCS8EncodedKeySpec },
            'java.nio.charset': { Charset: Charset, StandardCharsets: StandardCharsets },
            'java.net': {
                URLEncoder: URLEncoder, URLDecoder: URLDecoder, URL: JavaURL, HttpURLConnection: HttpURLConnection,
                Socket: Socket, InetSocketAddress: InetSocketAddress
            },
            'javax.net.ssl': { HttpsURLConnection: HttpURLConnection },
            'android.util': { Base64: AndroidBase64 },
            'android.text': { TextUtils: TextUtils },
            'android.webkit': { CookieManager: CookieManager },
            'io.legado.app.help.http': { StrResponse: StrResponse, CookieStore: LegadoCookieStore },
            'io.legado.app.model.analyzeRule': { AnalyzeRule: AnalyzeRule },
            'javax.crypto': { Cipher: Cipher, Mac: Mac, SecretKeyFactory: SecretKeyFactory },
            'javax.crypto.spec': { SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec, GCMParameterSpec: GCMParameterSpec, DESKeySpec: DESKeySpec },
            'cn.hutool.crypto.digest': { DigestUtil: DigestUtil },
            'cn.hutool.core.util': { StrUtil: StrUtil, ZipUtil: ZipUtil, HexUtil: HexUtil },
            'cn.hutool.core.codec': { Base64: HutoolBase64 },
            'okhttp3': {
                MediaType: MediaType, RequestBody: RequestBody, Request: Request, OkHttpClient: OkHttpClient,
                HttpUrl: HttpUrl, Headers: Headers
            }
        };
        function unsupported(path) {
            var c = global.__yueduLegadoErrorContext || {};
            throw new Error('UnsupportedLegadoAPIError: Packages.' + path + ' at ' + (c.stage || 'javascript') +
                ' (' + (c.sourceName || '?') + ' | ' + (c.sourceId || '?') + ')');
        }
        // `Packages.org.jsoup.*` is the global `org.jsoup` polyfill (installed after this file),
        // looked up when it is read. Rhino scripts reach jsoup by either name; the
        // `Packages` spelling threw UnsupportedLegadoAPIError (桔纸书屋, 台湾小说网, 格格党网).
        function globalAlias(path) {
            if (path !== 'org.jsoup' && path.indexOf('org.jsoup.') !== 0) return undefined;
            if (!isEnabled('org.jsoup')) return undefined;
            var value = global;
            var parts = path.split('.');
            for (var i = 0; i < parts.length; i++) {
                if (value == null) return undefined;
                value = value[parts[i]];
            }
            return value;
        }
        function makeNamespace(path) {
            var registered = members[path] || {}, mem = {}, target = function () {};
            Object.keys(registered).forEach(function (key) {
                var memberPath = path ? path + '.' + key : key;
                if (isEnabled(memberPath)) mem[key] = registered[key];
            });
            Object.defineProperty(target, '__members', { value: mem });
            Object.keys(mem).forEach(function (key) { target[key] = mem[key]; });
            return new NativeProxy(target, {
                get: function (t, property) {
                    if (typeof property !== 'string') return t[property];
                    if (Object.prototype.hasOwnProperty.call(t, property)) return t[property];
                    var childPath = path ? path + '.' + property : property;
                    var aliased = globalAlias(childPath);
                    if (aliased !== undefined) return aliased;
                    return makeNamespace(childPath);
                },
                apply: function () { return unsupported(path); },
                construct: function () {
                    var name = path.split('.').pop();
                    if (isEnabled(path) && /^(HashMap|LinkedHashMap|TreeMap|Hashtable|Properties)$/.test(name)) return __yueduJavaMap({});
                    if (isEnabled(path) && /^(ArrayList|LinkedList|Vector)$/.test(name)) return [];
                    return unsupported(path);
                }
            });
        }
        global.Packages = makeNamespace('');
        // Rhino's top-level package names (`ScriptRuntime.getTopPackageNames`, `android`
        // included on Dalvik): Legado's scopes are built on `initStandardObjects()`, so
        // `javax.crypto.Cipher` and `android.util.Base64` need no `Packages.` there. `org` is
        // the jsoup polyfill's own global (`Packages.org.jsoup` reads it).
        ['javax', 'android', 'com', 'edu', 'net'].forEach(function (name) {
            if (global[name] === undefined) global[name] = makeNamespace(name);
        });
        // `java` is the bridge here, in every scope. In Legado it is the bridge only in a rule's
        // own scope: a jsLib runs in a scope of its own, where `java` is Rhino's Java package,
        // and its functions resolve `java` there — 酷狗小说 (YCK1329) signs every request with
        // `java.security.MessageDigest` and `new java.lang.String(s).getBytes("UTF-8")` inside
        // a jsLib function, and with neither its signature came out empty. So the bridge also
        // answers the `java.*` subpackages. No bridge method has one of these names.
        if (global.java) {
            ['lang', 'util', 'io', 'nio', 'math', 'net', 'security', 'text', 'time'].forEach(function (name) {
                if (global.java[name] === undefined) {
                    Object.defineProperty(global.java, name, { value: makeNamespace('java.' + name), configurable: true });
                }
            });
        }
        global.JavaImporter = function () {
            var importer = {};
            importer.importPackage = function () {
                for (var i = 0; i < arguments.length; i++) {
                    var mem = arguments[i] && arguments[i].__members;
                    if (mem) Object.keys(mem).forEach(function (key) { importer[key] = mem[key]; });
                }
            };
            importer.importClass = importer.importPackage;
            return importer;
        };
        delete global.__yueduLegadoCapabilities;
    })(this);
    """#
}
