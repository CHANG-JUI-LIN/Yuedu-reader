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
        function utf8String(bytes) {
            var out = '', i = 0;
            while (i < bytes.length) {
                var c = bytes[i++];
                if (c < 128) out += String.fromCharCode(c);
                else if ((c & 224) === 192) out += String.fromCharCode(((c & 31) << 6) | (bytes[i++] & 63));
                else if ((c & 240) === 224) out += String.fromCharCode(((c & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63));
                else {
                    var cp = ((c & 7) << 18) | ((bytes[i++] & 63) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
                    cp -= 0x10000;
                    out += String.fromCharCode(0xd800 | (cp >> 10), 0xdc00 | (cp & 1023));
                }
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
            return utf8String(bytes);
        }
        function JavaString(value, a, b, c) {
            var stringValue;
            if (typeof value === 'string' || value instanceof String) stringValue = String(value);
            else if (typeof a === 'number') stringValue = bytesToString(value, c, a, b);
            else stringValue = bytesToString(value, a || 'UTF-8');
            var boxed = new String(stringValue);
            boxed.getBytes = function (charset) { return getBytes(stringValue, charset); };
            return boxed;
        }
        Object.defineProperty(String.prototype, 'getBytes', {
            value: function (charset) { return getBytes(String(this), charset); },
            enumerable: false, configurable: true, writable: true
        });

        function bytesToHex(bytes) {
            return unsignedBytes(bytes).map(function (v) { return (v < 16 ? '0' : '') + v.toString(16); }).join('');
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
            decode: function (value) { return decode64(value); }
        };
        var JavaBase64 = {
            getDecoder: function () { return { decode: decode64 }; },
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
        var Arrays = { copyOfRange: function (value, from, to) { return unsignedBytes(value).slice(Number(from), Number(to)); } };
        var System = { nanoTime: function () { return Date.now() * 1000000; }, currentTimeMillis: function () { return Date.now(); } };
        function SecretKeySpec(bytes, algorithm) { return { __bytes: unsignedBytes(bytes), __alg: String(algorithm || '') }; }
        function IvParameterSpec(bytes) { return { __bytes: unsignedBytes(bytes) }; }
        var Cipher = {
            ENCRYPT_MODE: 1, DECRYPT_MODE: 2,
            getInstance: function (transformation) {
                return {
                    __t: String(transformation), __mode: 0, __key: [], __iv: [],
                    init: function (mode, key, iv) { this.__mode = Number(mode); this.__key = unsignedBytes(key); this.__iv = unsignedBytes(iv); },
                    doFinal: function (data) {
                        var value = this.__mode === 1
                            ? java.aesEncryptHex(this.__t, bytesToHex(this.__key), bytesToHex(this.__iv), bytesToHex(data))
                            : java.aesDecryptHex(this.__t, bytesToHex(this.__key), bytesToHex(this.__iv), bytesToHex(data));
                        return hexToBytes(value);
                    }
                };
            }
        };
        var DigestUtil = { md5Hex: function (s) { return java.md5Encode(String(s)); } };
        var StrUtil = { reverse: function (s) { return String(s).split('').reverse().join(''); } };
        var HutoolBase64 = { encode: function (s) { return java.base64Encode(String(s)); }, decode: function (s) { return java.base64Decode(String(s)); } };

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
                decrypt: function (data) { return hexToBytes(java.aesDecryptHex(t, keyHex, ivHex, decryptInputHex(data))); },
                decryptStr: function (data) { return bytesToString(this.decrypt(data), 'UTF-8'); },
                encrypt: function (data) { return hexToBytes(java.aesEncryptHex(t, keyHex, ivHex, encryptInputHex(data))); },
                encryptBase64: function (data) { return encode64(this.encrypt(data), 2); },
                encryptHex: function (data) { return java.aesEncryptHex(t, keyHex, ivHex, encryptInputHex(data)); }
            };
        };
        java.aesBase64Decode = function (data, key, transformation, iv) {
            return hexToBytes(java.aesDecryptHex(String(transformation || 'AES'), bytesToHex(getBytes(key || '', 'UTF-8')), bytesToHex(getBytes(iv || '', 'UTF-8')), bytesToHex(decode64(data))));
        };
        java.aesBase64DecodeToString = function () { return bytesToString(java.aesBase64Decode.apply(java, arguments), 'UTF-8'); };

        var members = {
            'java.lang': { String: JavaString, System: System },
            'java.util': { Base64: JavaBase64, Arrays: Arrays, UUID: UUID },
            'android.util': { Base64: AndroidBase64 },
            'javax.crypto': { Cipher: Cipher },
            'javax.crypto.spec': { SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec },
            'cn.hutool.crypto.digest': { DigestUtil: DigestUtil },
            'cn.hutool.core.util': { StrUtil: StrUtil },
            'cn.hutool.core.codec': { Base64: HutoolBase64 }
        };
        function unsupported(path) {
            var c = global.__yueduLegadoErrorContext || {};
            throw new Error('UnsupportedLegadoAPIError: Packages.' + path + ' at ' + (c.stage || 'javascript') +
                ' (' + (c.sourceName || '?') + ' | ' + (c.sourceId || '?') + ')');
        }
        function makeNamespace(path) {
            var registered = members[path] || {}, mem = {}, target = function () {};
            Object.keys(registered).forEach(function (key) {
                if (isEnabled(path ? path + '.' + key : key)) mem[key] = registered[key];
            });
            Object.defineProperty(target, '__members', { value: mem });
            Object.keys(mem).forEach(function (key) { target[key] = mem[key]; });
            return new Proxy(target, {
                get: function (t, property) {
                    if (typeof property !== 'string') return t[property];
                    if (Object.prototype.hasOwnProperty.call(t, property)) return t[property];
                    return makeNamespace(path ? path + '.' + property : property);
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
