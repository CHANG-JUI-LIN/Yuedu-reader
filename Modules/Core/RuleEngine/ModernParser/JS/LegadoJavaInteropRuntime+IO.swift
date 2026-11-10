import Foundation

extension LegadoJavaInteropRuntime {
    /// The JVM classes Legado sources reach for when Legado's own `java.*` helpers stop short:
    /// byte streams, zlib, `HttpURLConnection`, `BigInteger`, `Mac`, AES-GCM, RSA keys and
    /// signatures, `StringBuilder`. They run inside the runtime script's closure and use its
    /// byte helpers (`unsignedBytes`, `getBytes`, `bytesToString`, `bytesToHex`,
    /// `hexToBytes`); the native work goes through the `java` bridge.
    ///
    /// The runtime works in 0–255 (`unsignedBytes`), and a value written into an array is masked
    /// when it is next read. What a script receives where Java types a `byte[]` — `doFinal`,
    /// `toByteArray`, a filled buffer, `ByteBuffer.get` — is Java's signed bytes (`javaBytes`),
    /// as Rhino hands them over: `b >> 2` on a negative byte is not the same as on its 0–255
    /// twin, and 西瓜免费 (YCK1331) encodes its HMAC sign with exactly that. `InputStream.read()`
    /// answers an int 0–255 in Java too, and stays so.
    ///
    /// Seen in the YCK 精校 packs (2026-11): 番茄 (URL.openConnection + GZIP streams +
    /// BigInteger + SecureRandom), 七猫 (Inflater + Arrays.copyOf), 微信读书 (InflaterInputStream,
    /// ByteBuffer), 洋柿子酱 (AES/GCM), 纸间阅读 (Mac), 西瓜小说 (Signature SHA256withRSA),
    /// 花花短剧 (StringBuilder + BufferedReader), 速读谷子 (Socket timing).
    static let ioScript = #"""
        // ---- java.io: byte streams ----
        function ByteArrayInputStream(bytes, offset, length) {
            var all = unsignedBytes(bytes);
            var start = offset == null ? 0 : Math.max(0, Number(offset));
            var end = length == null ? all.length : Math.min(all.length, start + Number(length));
            this._bytes = all; this._pos = start; this._end = end; this._mark = start;
        }
        ByteArrayInputStream.prototype.read = function (buffer, offset, length) {
            if (buffer === undefined) return this._pos < this._end ? this._bytes[this._pos++] : -1;
            var off = offset == null ? 0 : Number(offset);
            var len = length == null ? buffer.length - off : Number(length);
            if (len <= 0) return 0;
            if (this._pos >= this._end) return -1;
            var n = Math.min(len, this._end - this._pos);
            for (var i = 0; i < n; i++) buffer[off + i] = javaByte(this._bytes[this._pos++]);
            return n;
        };
        ByteArrayInputStream.prototype.readAllBytes = function () {
            var rest = this._bytes.slice(this._pos, this._end);
            this._pos = this._end;
            return javaBytes(rest);
        };
        ByteArrayInputStream.prototype.readNBytes = function (a, b, c) {
            if (typeof a === 'number') {
                var take = this._bytes.slice(this._pos, Math.min(this._end, this._pos + a));
                this._pos += take.length;
                return javaBytes(take);
            }
            var n = this.read(a, b, c);
            return n < 0 ? 0 : n;
        };
        ByteArrayInputStream.prototype.available = function () { return this._end - this._pos; };
        ByteArrayInputStream.prototype.skip = function (n) {
            var k = Math.max(0, Math.min(Number(n), this._end - this._pos));
            this._pos += k;
            return k;
        };
        ByteArrayInputStream.prototype.transferTo = function (out) {
            var rest = this.readAllBytes();
            out.write(rest, 0, rest.length);
            return rest.length;
        };
        ByteArrayInputStream.prototype.markSupported = function () { return true; };
        ByteArrayInputStream.prototype.mark = function () { this._mark = this._pos; };
        ByteArrayInputStream.prototype.reset = function () { this._pos = this._mark; };
        ByteArrayInputStream.prototype.close = function () {};

        // Everything a stream will ever answer, read out now: `in`'s remaining bytes.
        function drainStream(stream) {
            if (stream == null) return [];
            if (stream instanceof ByteArrayInputStream) return unsignedBytes(stream.readAllBytes());
            if (typeof stream.readAllBytes === 'function') return unsignedBytes(stream.readAllBytes());
            var out = [], buffer = new Array(8192), n;
            while ((n = stream.read(buffer, 0, buffer.length)) > 0) {
                for (var i = 0; i < n; i++) out.push(Number(buffer[i]) & 255);
            }
            return out;
        }

        // An input stream whose bytes are produced on first use: a decompressing stream reads
        // and inflates its source then, as Java's would before its first byte.
        function DerivedInputStream(produce) { this._produce = produce; this._inner = null; }
        DerivedInputStream.prototype._open = function () {
            if (!this._inner) this._inner = new ByteArrayInputStream(this._produce());
            return this._inner;
        };
        ['read', 'readAllBytes', 'readNBytes', 'available', 'skip', 'transferTo'].forEach(function (name) {
            DerivedInputStream.prototype[name] = function () {
                var inner = this._open();
                return inner[name].apply(inner, arguments);
            };
        });
        DerivedInputStream.prototype.markSupported = function () { return false; };
        DerivedInputStream.prototype.close = function () {};

        function ByteArrayOutputStream() { this._bytes = []; }
        ByteArrayOutputStream.prototype.write = function (value, offset, length) {
            if (typeof value === 'number') { this._bytes.push(value & 255); return; }
            var bytes = unsignedBytes(value);
            var off = offset == null ? 0 : Number(offset);
            var end = length == null ? bytes.length : off + Number(length);
            for (var i = off; i < end && i < bytes.length; i++) this._bytes.push(bytes[i]);
        };
        ByteArrayOutputStream.prototype.writeBytes = function (value) { this.write(value); };
        ByteArrayOutputStream.prototype.writeTo = function (out) { out.write(this._bytes, 0, this._bytes.length); };
        ByteArrayOutputStream.prototype.toByteArray = function () { return javaBytes(this._bytes); };
        ByteArrayOutputStream.prototype.size = function () { return this._bytes.length; };
        ByteArrayOutputStream.prototype.reset = function () { this._bytes = []; };
        ByteArrayOutputStream.prototype.toString = function (charset) { return bytesToString(this._bytes, charset || 'UTF-8'); };
        ByteArrayOutputStream.prototype.flush = function () {};
        ByteArrayOutputStream.prototype.close = function () {};

        // A wrapper that writes through to another stream (DataOutputStream, BufferedOutputStream).
        function FilterOutputStream(out) { this._out = out; this._written = 0; }
        FilterOutputStream.prototype.write = function (value, offset, length) {
            var before = this._written;
            if (typeof value === 'number') { this._out.write(value & 255); this._written = before + 1; return; }
            var bytes = unsignedBytes(value);
            var off = offset == null ? 0 : Number(offset);
            var len = length == null ? bytes.length - off : Number(length);
            this._out.write(bytes, off, len);
            this._written = before + len;
        };
        FilterOutputStream.prototype.writeBytes = function (s) {
            var text = String(s), bytes = [];
            for (var i = 0; i < text.length; i++) bytes.push(text.charCodeAt(i) & 255);
            this.write(bytes, 0, bytes.length);
        };
        FilterOutputStream.prototype.writeUTF = function (s) {
            var bytes = getBytes(String(s), 'UTF-8');
            this.write([(bytes.length >> 8) & 255, bytes.length & 255]);
            this.write(bytes, 0, bytes.length);
        };
        FilterOutputStream.prototype.writeInt = function (v) {
            this.write([(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255]);
        };
        FilterOutputStream.prototype.writeByte = function (v) { this.write(Number(v) & 255); };
        FilterOutputStream.prototype.size = function () { return this._written; };
        FilterOutputStream.prototype.flush = function () { if (this._out.flush) this._out.flush(); };
        FilterOutputStream.prototype.close = function () { this.flush(); if (this._out.close) this._out.close(); };
        function DataOutputStream(out) { FilterOutputStream.call(this, out); }
        DataOutputStream.prototype = Object.create(FilterOutputStream.prototype);
        function BufferedOutputStream(out) { FilterOutputStream.call(this, out); }
        BufferedOutputStream.prototype = Object.create(FilterOutputStream.prototype);

        // ---- java.io: character streams ----
        function charsetOf(value) { return value == null ? 'UTF-8' : String(value); }
        function InputStreamReader(stream, charset) {
            this._stream = stream; this._charset = charsetOf(charset); this._text = null; this._pos = 0;
        }
        function StringReader(text) { this._text = String(text); this._pos = 0; }
        function readerText(reader) {
            if (reader._text == null) reader._text = bytesToString(drainStream(reader._stream), reader._charset);
            return reader._text;
        }
        [InputStreamReader, StringReader].forEach(function (Reader) {
            Reader.prototype.read = function (buffer, offset, length) {
                var text = readerText(this);
                if (buffer === undefined) return this._pos < text.length ? text.charCodeAt(this._pos++) : -1;
                var off = offset == null ? 0 : Number(offset);
                var len = length == null ? buffer.length - off : Number(length);
                if (this._pos >= text.length) return -1;
                var n = Math.min(len, text.length - this._pos);
                for (var i = 0; i < n; i++) buffer[off + i] = text.charAt(this._pos++);
                return n;
            };
            Reader.prototype.ready = function () { return this._pos < readerText(this).length; };
            Reader.prototype.close = function () {};
        });
        function BufferedReader(reader) { this._reader = reader; this._text = null; this._pos = 0; }
        BufferedReader.prototype._all = function () {
            if (this._text != null) return this._text;
            var inner = this._reader;
            if (inner instanceof BufferedReader) {
                var rest = inner._all().slice(inner._pos);
                inner._pos = inner._all().length;
                this._text = rest;
            } else if (inner && (inner._stream !== undefined || inner instanceof StringReader)) {
                var text = readerText(inner);
                this._text = text.slice(inner._pos);
                inner._pos = text.length;
            } else {
                var out = '', c;
                while ((c = inner.read()) >= 0) out += String.fromCharCode(c);
                this._text = out;
            }
            return this._text;
        };
        // Java's readLine: a line ends at \n, \r or \r\n; the terminator is not returned, and
        // the end of the input after a terminator is not another (empty) line.
        BufferedReader.prototype.readLine = function () {
            var text = this._all();
            if (this._pos >= text.length) return null;
            var start = this._pos, i = start;
            while (i < text.length && text.charAt(i) !== '\n' && text.charAt(i) !== '\r') i++;
            var line = text.slice(start, i);
            if (i < text.length) {
                if (text.charAt(i) === '\r' && text.charAt(i + 1) === '\n') i++;
                i++;
            }
            this._pos = i;
            return line;
        };
        BufferedReader.prototype.read = function () {
            var text = this._all();
            return this._pos < text.length ? text.charCodeAt(this._pos++) : -1;
        };
        BufferedReader.prototype.lines = function () {
            var lines = [], line;
            while ((line = this.readLine()) !== null) lines.push(line);
            return lines;
        };
        BufferedReader.prototype.ready = function () { return this._pos < this._all().length; };
        BufferedReader.prototype.close = function () {};

        function OutputStreamWriter(out, charset) { this._out = out; this._charset = charsetOf(charset); }
        OutputStreamWriter.prototype.write = function (value, offset, length) {
            var text = typeof value === 'number' ? String.fromCharCode(value) : String(value);
            if (offset != null) text = text.substr(Number(offset), Number(length));
            var bytes = getBytes(text, this._charset);
            this._out.write(bytes, 0, bytes.length);
        };
        OutputStreamWriter.prototype.append = function (value) { this.write(String(value)); return this; };
        OutputStreamWriter.prototype.flush = function () { if (this._out.flush) this._out.flush(); };
        OutputStreamWriter.prototype.close = function () { this.flush(); if (this._out.close) this._out.close(); };
        function BufferedWriter(writer) { this._writer = writer; }
        BufferedWriter.prototype.write = function (a, b, c) { this._writer.write(a, b, c); };
        BufferedWriter.prototype.append = function (value) { this._writer.write(String(value)); return this; };
        BufferedWriter.prototype.newLine = function () { this._writer.write('\n'); };
        BufferedWriter.prototype.flush = function () { this._writer.flush(); };
        BufferedWriter.prototype.close = function () { this._writer.close(); };

        // ---- java.util.zip ----
        function nativeInflate(bytes, windowBits) {
            return java.inflateBytes(bytes, windowBits);
        }
        // Java's Inflater keeps its state between calls; a source may feed input in pieces
        // (`needsInput()` → `setInput(next)`). Every piece is kept and the whole is inflated
        // again, handing out only what has not been handed out yet.
        function Inflater(nowrap) {
            this._nowrap = !!nowrap; this._input = []; this._result = null; this._delivered = 0;
        }
        Inflater.prototype.setInput = function (bytes, offset, length) {
            var all = unsignedBytes(bytes);
            var off = offset == null ? 0 : Number(offset);
            var end = length == null ? all.length : off + Number(length);
            this._input = this._input.concat(all.slice(off, end));
            this._result = null;
        };
        Inflater.prototype._run = function () {
            if (!this._result) this._result = nativeInflate(this._input, this._nowrap ? -15 : 15);
            return this._result;
        };
        Inflater.prototype.inflate = function (buffer, offset, length) {
            var result = this._run(), bytes = result.bytes;
            var off = offset == null ? 0 : Number(offset);
            var len = length == null ? buffer.length - off : Number(length);
            var n = Math.max(0, Math.min(len, bytes.length - this._delivered));
            for (var i = 0; i < n; i++) buffer[off + i] = javaByte(bytes[this._delivered++]);
            return n;
        };
        Inflater.prototype.finished = function () {
            var result = this._run();
            return result.finished && this._delivered >= result.bytes.length;
        };
        Inflater.prototype.needsInput = function () {
            var result = this._run();
            return !result.finished && this._delivered >= result.bytes.length;
        };
        Inflater.prototype.needsDictionary = function () { return false; };
        Inflater.prototype.getRemaining = function () {
            var result = this._run();
            return result.finished ? Math.max(0, this._input.length - result.consumed) : 0;
        };
        Inflater.prototype.getTotalOut = Inflater.prototype.getBytesWritten = function () { return this._delivered; };
        Inflater.prototype.getTotalIn = Inflater.prototype.getBytesRead = function () {
            var result = this._run();
            return result.finished ? result.consumed : this._input.length;
        };
        Inflater.prototype.reset = function () { this._input = []; this._result = null; this._delivered = 0; };
        Inflater.prototype.end = function () {};

        function inflatedStream(source, windowBits) {
            return new DerivedInputStream(function () {
                var result = nativeInflate(drainStream(source), windowBits);
                if (!result.finished) throw new Error('java.io.EOFException: Unexpected end of ZLIB input stream');
                return result.bytes;
            });
        }
        function InflaterInputStream(source, inflater) {
            return inflatedStream(source, inflater && inflater._nowrap ? -15 : 15);
        }
        function GZIPInputStream(source) { return inflatedStream(source, 31); }
        // Java writes the gzip member when the stream is finished or closed.
        function GZIPOutputStream(out) { this._out = out; this._buffer = new ByteArrayOutputStream(); this._done = false; }
        GZIPOutputStream.prototype.write = function (value, offset, length) { this._buffer.write(value, offset, length); };
        GZIPOutputStream.prototype.finish = function () {
            if (this._done) return;
            this._done = true;
            var bytes = java.gzipBytes(this._buffer.toByteArray());
            this._out.write(bytes, 0, bytes.length);
        };
        GZIPOutputStream.prototype.flush = function () {};
        GZIPOutputStream.prototype.close = function () { this.finish(); if (this._out.close) this._out.close(); };

        // ---- java.lang ----
        function StringBuilder(initial) {
            if (!(this instanceof StringBuilder)) return new StringBuilder(initial);
            this._s = initial == null || typeof initial === 'number' ? '' : String(initial);
        }
        StringBuilder.prototype.append = function (value, start, end) {
            var text = value === null ? 'null' : String(value);
            if (start != null) text = text.slice(Number(start), Number(end));
            this._s += text;
            return this;
        };
        StringBuilder.prototype.insert = function (index, value) {
            var i = Number(index);
            this._s = this._s.slice(0, i) + (value === null ? 'null' : String(value)) + this._s.slice(i);
            return this;
        };
        StringBuilder.prototype.reverse = function () { this._s = Array.from(this._s).reverse().join(''); return this; };
        StringBuilder.prototype.length = function () { return this._s.length; };
        StringBuilder.prototype.isEmpty = function () { return this._s.length === 0; };
        StringBuilder.prototype.charAt = function (i) { return this._s.charAt(Number(i)); };
        StringBuilder.prototype.setCharAt = function (i, c) {
            var k = Number(i);
            this._s = this._s.slice(0, k) + String(c).charAt(0) + this._s.slice(k + 1);
        };
        StringBuilder.prototype.deleteCharAt = function (i) {
            var k = Number(i);
            this._s = this._s.slice(0, k) + this._s.slice(k + 1);
            return this;
        };
        StringBuilder.prototype['delete'] = function (start, end) {
            this._s = this._s.slice(0, Number(start)) + this._s.slice(Math.min(this._s.length, Number(end)));
            return this;
        };
        StringBuilder.prototype.replace = function (start, end, text) {
            this._s = this._s.slice(0, Number(start)) + String(text) + this._s.slice(Math.min(this._s.length, Number(end)));
            return this;
        };
        StringBuilder.prototype.setLength = function (n) {
            var k = Number(n);
            this._s = k <= this._s.length ? this._s.slice(0, k) : this._s + new Array(k - this._s.length + 1).join('\u0000');
        };
        StringBuilder.prototype.indexOf = function (s, from) { return this._s.indexOf(String(s), from == null ? 0 : Number(from)); };
        StringBuilder.prototype.lastIndexOf = function (s, from) {
            return from == null ? this._s.lastIndexOf(String(s)) : this._s.lastIndexOf(String(s), Number(from));
        };
        StringBuilder.prototype.substring = function (start, end) {
            return end == null ? this._s.substring(Number(start)) : this._s.substring(Number(start), Number(end));
        };
        StringBuilder.prototype.toString = function () { return this._s; };
        StringBuilder.prototype.valueOf = function () { return this._s; };

        var JavaByte = {
            TYPE: 'byte', MIN_VALUE: -128, MAX_VALUE: 127, SIZE: 8, BYTES: 1,
            parseByte: function (s, radix) {
                var v = Integer.parseInt(s, radix);
                if (v < -128 || v > 127) throw new Error('java.lang.NumberFormatException: Value out of range. Value:"' + s + '"');
                return v;
            },
            toUnsignedInt: function (b) { return Number(b) & 255; },
            valueOf: function (b) { var v = Number(b) & 255; return v > 127 ? v - 256 : v; }
        };
        // java.lang.reflect.Array.newInstance(Byte.TYPE, n): a zero-filled array of n.
        var ReflectArray = {
            newInstance: function (type, length) {
                var n = Number(length), zero = type === 'boolean' ? false : 0, out = new Array(n);
                for (var i = 0; i < n; i++) out[i] = zero;
                return out;
            },
            getLength: function (array) { return array.length; },
            get: function (array, i) { return array[Number(i)]; },
            set: function (array, i, v) { array[Number(i)] = v; }
        };

        // ---- java.nio.ByteBuffer: the array-backed, big-endian buffer ----
        function ByteBuffer(bytes) { this._bytes = bytes; this._pos = 0; this._limit = bytes.length; }
        ByteBuffer.allocate = function (n) { return new ByteBuffer(ReflectArray.newInstance('byte', n)); };
        ByteBuffer.wrap = function (bytes, offset, length) {
            var buffer = new ByteBuffer(bytes);
            if (offset != null) { buffer._pos = Number(offset); buffer._limit = Number(offset) + Number(length); }
            return buffer;
        };
        ByteBuffer.prototype.array = function () { return this._bytes; };
        ByteBuffer.prototype.capacity = function () { return this._bytes.length; };
        ByteBuffer.prototype.position = function (p) { if (p === undefined) return this._pos; this._pos = Number(p); return this; };
        ByteBuffer.prototype.limit = function (l) { if (l === undefined) return this._limit; this._limit = Number(l); return this; };
        ByteBuffer.prototype.remaining = function () { return this._limit - this._pos; };
        ByteBuffer.prototype.hasRemaining = function () { return this._pos < this._limit; };
        ByteBuffer.prototype.flip = function () { this._limit = this._pos; this._pos = 0; return this; };
        ByteBuffer.prototype.clear = function () { this._pos = 0; this._limit = this._bytes.length; return this; };
        ByteBuffer.prototype.rewind = function () { this._pos = 0; return this; };
        ByteBuffer.prototype.order = function (order) { return order === undefined ? 'BIG_ENDIAN' : this; };
        ByteBuffer.prototype.put = function (value, offset, length) {
            if (typeof value === 'number') { this._bytes[this._pos++] = javaByte(value); return this; }
            var bytes = unsignedBytes(value);
            var off = offset == null ? 0 : Number(offset);
            var end = length == null ? bytes.length : off + Number(length);
            for (var i = off; i < end; i++) this._bytes[this._pos++] = javaByte(bytes[i]);
            return this;
        };
        // Java's `get` is a byte: signed, as the backing `array()` holds it.
        ByteBuffer.prototype.get = function (target, offset, length) {
            if (target === undefined) return javaByte(this._bytes[this._pos++]);
            if (typeof target === 'number') return javaByte(this._bytes[target]);
            var off = offset == null ? 0 : Number(offset);
            var len = length == null ? target.length - off : Number(length);
            for (var i = 0; i < len; i++) target[off + i] = javaByte(this._bytes[this._pos++]);
            return this;
        };
        ByteBuffer.prototype.putShort = function (v) { return this.put([(v >> 8) & 255, v & 255]); };
        ByteBuffer.prototype.putInt = function (v) { return this.put([(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255]); };
        ByteBuffer.prototype.getShort = function () { var v = ((this.get() & 255) << 8) | (this.get() & 255); return v > 32767 ? v - 65536 : v; };
        ByteBuffer.prototype.getInt = function () {
            return ((this.get() & 255) << 24) | ((this.get() & 255) << 16) | ((this.get() & 255) << 8) | (this.get() & 255);
        };

        // ---- java.math.BigInteger over the engine's BigInt ----
        function big(value) { return value instanceof BigInteger ? value._v : BigInt(value); }
        function BigInteger(a, b) {
            if (!(this instanceof BigInteger)) return new BigInteger(a, b);
            if (typeof a === 'bigint') { this._v = a; return; }
            if (typeof a === 'number' && b != null && typeof b.nextBytes === 'function') {
                // (numBits, rnd): uniform in [0, 2^numBits), Java's own construction.
                var bits = Number(a), count = Math.ceil(bits / 8), random = new Array(count);
                b.nextBytes(random);
                var excess = count * 8 - bits;
                if (count > 0) random[0] = (Number(random[0]) & 255) & ((1 << (8 - excess)) - 1);
                this._v = magnitude(random);
                return;
            }
            if (typeof a === 'number' && b != null && typeof b !== 'number' && typeof b !== 'string') {
                // (signum, magnitude)
                var m = magnitude(b);
                this._v = Number(a) < 0 ? -m : m;
                return;
            }
            if (typeof a === 'string' || a instanceof String) {
                this._v = parseBig(String(a), b == null ? 10 : Number(b));
                return;
            }
            // (byte[]): two's complement, big-endian.
            var bytes = unsignedBytes(a), v = magnitude(bytes);
            if (bytes.length && bytes[0] > 127) v -= BigInt(1) << BigInt(8 * bytes.length);
            this._v = v;
        }
        function magnitude(bytes) {
            var v = BigInt(0), eight = BigInt(8);
            for (var i = 0; i < bytes.length; i++) v = (v << eight) | BigInt(Number(bytes[i]) & 255);
            return v;
        }
        function parseBig(text, radix) {
            var s = text.trim(), negative = false;
            if (s.charAt(0) === '-' || s.charAt(0) === '+') { negative = s.charAt(0) === '-'; s = s.slice(1); }
            var digits = '0123456789abcdefghijklmnopqrstuvwxyz'.slice(0, radix);
            if (!s.length || !s.toLowerCase().split('').every(function (ch) { return digits.indexOf(ch) >= 0; })) {
                throw new Error('java.lang.NumberFormatException: For input string: "' + text + '"');
            }
            var v = BigInt(0), r = BigInt(radix);
            for (var i = 0; i < s.length; i++) v = v * r + BigInt(digits.indexOf(s.charAt(i).toLowerCase()));
            return negative ? -v : v;
        }
        function wrapBig(v) { return new BigInteger(v); }
        BigInteger.valueOf = function (n) { return wrapBig(BigInt(Math.trunc(Number(n)))); };
        BigInteger.prototype.add = function (o) { return wrapBig(this._v + big(o)); };
        BigInteger.prototype.subtract = function (o) { return wrapBig(this._v - big(o)); };
        BigInteger.prototype.multiply = function (o) { return wrapBig(this._v * big(o)); };
        BigInteger.prototype.divide = function (o) {
            var d = big(o);
            if (d === BigInt(0)) throw new Error('java.lang.ArithmeticException: BigInteger divide by zero');
            return wrapBig(this._v / d);
        };
        BigInteger.prototype.remainder = function (o) { return wrapBig(this._v % big(o)); };
        BigInteger.prototype.mod = function (o) {
            var m = big(o);
            if (m <= BigInt(0)) throw new Error('java.lang.ArithmeticException: BigInteger: modulus not positive');
            var r = this._v % m;
            return wrapBig(r < BigInt(0) ? r + m : r);
        };
        BigInteger.prototype.modPow = function (e, m) {
            var exponent = big(e), modulus = big(m), zero = BigInt(0), one = BigInt(1);
            if (modulus <= zero) throw new Error('java.lang.ArithmeticException: BigInteger: modulus not positive');
            var base = this.mod(m)._v;
            if (exponent < zero) { base = this.modInverse(m)._v; exponent = -exponent; }
            var result = one % modulus;
            while (exponent > zero) {
                if (exponent & one) result = (result * base) % modulus;
                base = (base * base) % modulus;
                exponent >>= one;
            }
            return wrapBig(result);
        };
        BigInteger.prototype.modInverse = function (m) {
            var modulus = big(m), zero = BigInt(0), one = BigInt(1);
            var a = this.mod(m)._v, b = modulus, x0 = one, x1 = zero;
            while (b !== zero) {
                var q = a / b, t = a - q * b;
                a = b; b = t;
                t = x0 - q * x1; x0 = x1; x1 = t;
            }
            if (a !== one) throw new Error('java.lang.ArithmeticException: BigInteger not invertible.');
            return wrapBig(((x0 % modulus) + modulus) % modulus);
        };
        BigInteger.prototype.pow = function (n) { return wrapBig(this._v ** BigInt(Number(n))); };
        BigInteger.prototype.gcd = function (o) {
            var a = this._v < BigInt(0) ? -this._v : this._v, b = big(o);
            if (b < BigInt(0)) b = -b;
            while (b !== BigInt(0)) { var t = a % b; a = b; b = t; }
            return wrapBig(a);
        };
        BigInteger.prototype.negate = function () { return wrapBig(-this._v); };
        BigInteger.prototype.abs = function () { return wrapBig(this._v < BigInt(0) ? -this._v : this._v); };
        BigInteger.prototype.signum = function () { return this._v > BigInt(0) ? 1 : (this._v < BigInt(0) ? -1 : 0); };
        BigInteger.prototype.compareTo = function (o) { var v = big(o); return this._v > v ? 1 : (this._v < v ? -1 : 0); };
        BigInteger.prototype.equals = function (o) { return o instanceof BigInteger && o._v === this._v; };
        BigInteger.prototype.min = function (o) { return this.compareTo(o) <= 0 ? this : o; };
        BigInteger.prototype.max = function (o) { return this.compareTo(o) >= 0 ? this : o; };
        BigInteger.prototype.and = function (o) { return wrapBig(this._v & big(o)); };
        BigInteger.prototype.or = function (o) { return wrapBig(this._v | big(o)); };
        BigInteger.prototype.xor = function (o) { return wrapBig(this._v ^ big(o)); };
        BigInteger.prototype.not = function () { return wrapBig(~this._v); };
        BigInteger.prototype.shiftLeft = function (n) { return wrapBig(this._v << BigInt(Number(n))); };
        BigInteger.prototype.shiftRight = function (n) { return wrapBig(this._v >> BigInt(Number(n))); };
        BigInteger.prototype.testBit = function (n) { return ((this._v >> BigInt(Number(n))) & BigInt(1)) === BigInt(1); };
        BigInteger.prototype.bitLength = function () {
            var v = this._v < BigInt(0) ? ~this._v : this._v;
            return v === BigInt(0) ? 0 : v.toString(2).length;
        };
        BigInteger.prototype.toByteArray = function () {
            var length = Math.floor(this.bitLength() / 8) + 1, out = [];
            for (var i = length - 1; i >= 0; i--) out.push(Number(BigInt.asUintN(8, this._v >> BigInt(8 * i))));
            return javaBytes(out);
        };
        BigInteger.prototype.intValue = function () { return Number(BigInt.asIntN(32, this._v)); };
        BigInteger.prototype.longValue = function () { return Number(BigInt.asIntN(64, this._v)); };
        BigInteger.prototype.doubleValue = function () { return Number(this._v); };
        BigInteger.prototype.toString = function (radix) { return this._v.toString(radix == null ? 10 : Number(radix)); };
        if (typeof BigInt === 'function') {
            BigInteger.ZERO = wrapBig(BigInt(0)); BigInteger.ONE = wrapBig(BigInt(1));
            BigInteger.TWO = wrapBig(BigInt(2)); BigInteger.TEN = wrapBig(BigInt(10));
        }

        // ---- java.security ----
        function SecureRandom() {}
        SecureRandom.getInstance = SecureRandom.getInstanceStrong = function () { return new SecureRandom(); };
        SecureRandom.prototype.nextBytes = function (bytes) {
            var random = java.secureRandomBytes(bytes.length);
            for (var i = 0; i < bytes.length; i++) bytes[i] = javaByte(random[i]);
        };
        SecureRandom.prototype.generateSeed = function (n) { return javaBytes(java.secureRandomBytes(Number(n))); };
        SecureRandom.prototype.nextInt = function (bound) {
            var b = java.secureRandomBytes(4);
            var v = ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) >>> 0;
            if (bound == null) return v | 0;
            return Math.floor((v / 4294967296) * Number(bound));
        };
        SecureRandom.prototype.nextDouble = function () {
            var b = java.secureRandomBytes(4);
            return (((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) >>> 0) / 4294967296;
        };
        SecureRandom.prototype.nextBoolean = function () { return (java.secureRandomBytes(1)[0] & 1) === 1; };
        SecureRandom.prototype.setSeed = function () {};

        function encodedKeySpec(format) {
            return function (bytes) {
                var der = unsignedBytes(bytes);
                return { __der: der, getEncoded: function () { return javaBytes(der); }, getFormat: function () { return format; } };
            };
        }
        var X509EncodedKeySpec = encodedKeySpec('X.509');
        var PKCS8EncodedKeySpec = encodedKeySpec('PKCS#8');
        function rsaKey(kind, der) {
            return {
                __rsa: kind, __der: der,
                getEncoded: function () { return javaBytes(der); },
                getAlgorithm: function () { return 'RSA'; },
                getFormat: function () { return kind === 'public' ? 'X.509' : 'PKCS#8'; }
            };
        }
        var KeyFactory = {
            getInstance: function (algorithm) {
                if (!/^RSA$/i.test(String(algorithm))) throw new Error('java.security.NoSuchAlgorithmException: ' + algorithm + ' KeyFactory not available');
                return {
                    generatePublic: function (spec) { return rsaKey('public', spec.__der); },
                    generatePrivate: function (spec) { return rsaKey('private', spec.__der); }
                };
            }
        };
        function JavaSignature(algorithm) { this._alg = algorithm; this._key = null; this._buf = []; }
        JavaSignature.prototype.initSign = function (key) { this._key = key; this._buf = []; };
        JavaSignature.prototype.initVerify = function (key) { this._key = key; this._buf = []; };
        JavaSignature.prototype.update = MessageDigest.prototype.update;
        JavaSignature.prototype.sign = function () {
            var out = javaBytes(hexToBytes(java.rsaSignHex(this._alg, bytesToHex(this._key.__der), bytesToHex(this._buf))));
            this._buf = [];
            return out;
        };
        JavaSignature.prototype.verify = function (signature) {
            var ok = java.rsaVerify(this._alg, bytesToHex(this._key.__der), bytesToHex(this._buf), bytesToHex(signature));
            this._buf = [];
            return ok;
        };
        JavaSignature.prototype.getAlgorithm = function () { return this._alg; };
        var Signature = { getInstance: function (algorithm) { return new JavaSignature(String(algorithm)); } };

        // ---- javax.crypto ----
        function GCMParameterSpec(tagBits, iv, offset, length) {
            var bytes = unsignedBytes(iv);
            if (offset != null) bytes = bytes.slice(Number(offset), Number(offset) + Number(length));
            return {
                __bytes: bytes, __tagBits: Number(tagBits),
                getIV: function () { return javaBytes(bytes); }, getTLen: function () { return Number(tagBits); }
            };
        }
        function JavaCipher(transformation) {
            this.__t = transformation; this.__mode = 0; this.__key = null; this.__iv = [];
            this.__tagBits = 128; this.__buf = []; this.__aad = [];
        }
        JavaCipher.prototype._isRSA = function () { return /^RSA/i.test(this.__t); };
        JavaCipher.prototype._isGCM = function () { return /\/GCM\//i.test(this.__t); };
        JavaCipher.prototype.init = function (mode, key, params) {
            this.__mode = Number(mode); this.__key = key;
            this.__iv = params == null || typeof params.nextBytes === 'function' ? [] : unsignedBytes(params);
            this.__tagBits = params && params.__tagBits ? params.__tagBits : 128;
            this.__buf = []; this.__aad = [];
        };
        JavaCipher.prototype.updateAAD = function (bytes, offset, length) {
            var all = unsignedBytes(bytes);
            if (offset != null) all = all.slice(Number(offset), Number(offset) + Number(length));
            this.__aad = this.__aad.concat(all);
        };
        // Everything is enciphered at doFinal; update hands back nothing, so a source that
        // joins update's output with doFinal's gets the whole, as with Java.
        JavaCipher.prototype.update = function (bytes, offset, length) {
            var all = unsignedBytes(bytes);
            if (offset != null) all = all.slice(Number(offset), Number(offset) + Number(length));
            this.__buf = this.__buf.concat(all);
            return [];
        };
        JavaCipher.prototype.doFinal = function (bytes, offset, length) {
            if (bytes != null) this.update(bytes, offset, length);
            var data = this.__buf, encrypt = this.__mode === 1 || this.__mode === 3;
            this.__buf = [];
            if (this._isRSA()) {
                var key = this.__key || {};
                return javaBytes(hexToBytes(java.rsaCryptHex(this.__t, bytesToHex(key.__der || []), key.__rsa !== 'private', encrypt, bytesToHex(data))));
            }
            var keyHex = bytesToHex(this.__key), ivHex = bytesToHex(this.__iv);
            if (this._isGCM()) {
                var aad = this.__aad;
                this.__aad = [];
                return javaBytes(hexToBytes(java.aesGcmHex(encrypt, keyHex, ivHex, bytesToHex(aad), this.__tagBits, bytesToHex(data))));
            }
            return javaBytes(hexToBytes(encrypt
                ? java.aesEncryptHex(this.__t, keyHex, ivHex, bytesToHex(data))
                : java.aesDecryptHex(this.__t, keyHex, ivHex, bytesToHex(data))));
        };
        // Conscrypt's answer: an RSA cipher's block is the modulus to decrypt, eleven bytes
        // less to encrypt with PKCS#1 padding. A block cipher's is its block.
        JavaCipher.prototype.getBlockSize = function () {
            if (this._isRSA()) {
                var key = this.__key || {};
                var size = java.rsaKeySizeBytes(bytesToHex(key.__der || []), key.__rsa !== 'private');
                var encrypt = this.__mode === 1 || this.__mode === 3;
                return encrypt && !/NOPADDING/i.test(this.__t) ? size - 11 : size;
            }
            return /^(DES|DESEDE|3DES|TRIPLEDES)\b/i.test(this.__t) ? 8 : 16;
        };
        JavaCipher.prototype.getIV = function () { return javaBytes(this.__iv); };
        JavaCipher.prototype.getAlgorithm = function () { return this.__t; };
        var Cipher = {
            ENCRYPT_MODE: 1, DECRYPT_MODE: 2, WRAP_MODE: 3, UNWRAP_MODE: 4,
            getInstance: function (transformation) { return new JavaCipher(String(transformation)); }
        };
        function JavaMac(algorithm) { this._alg = algorithm; this._key = []; this._buf = []; }
        JavaMac.prototype.init = function (key) { this._key = unsignedBytes(key); this._buf = []; };
        JavaMac.prototype.update = MessageDigest.prototype.update;
        JavaMac.prototype.doFinal = function (input) {
            if (input != null) this.update(input);
            var out = javaBytes(java.hmacBytes(this._buf, this._alg, this._key));
            this._buf = [];
            return out;
        };
        JavaMac.prototype.reset = function () { this._buf = []; };
        JavaMac.prototype.getAlgorithm = function () { return this._alg; };
        JavaMac.prototype.getMacLength = function () {
            var name = this._alg.toUpperCase();
            return /512/.test(name) ? 64 : /384/.test(name) ? 48 : /256/.test(name) ? 32 : /224/.test(name) ? 28 : /MD5/.test(name) ? 16 : 20;
        };
        var Mac = { getInstance: function (algorithm) { return new JavaMac(String(algorithm)); } };

        // ---- java.net ----
        var urlPattern = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/;
        function JavaURL(context, spec) {
            if (!(this instanceof JavaURL)) return new JavaURL(context, spec);
            var text = spec === undefined ? String(context) : String(java.absoluteURL(String(spec), String(context)));
            var match = urlPattern.exec(text);
            if (!match) throw new Error('java.net.MalformedURLException: no protocol: ' + text);
            var authority = match[2], hostPort = authority.slice(authority.lastIndexOf('@') + 1);
            var portMatch = /:(\d+)$/.exec(hostPort);
            this._text = text;
            this._protocol = match[1].toLowerCase();
            this._authority = authority;
            this._host = portMatch ? hostPort.slice(0, portMatch.index) : hostPort;
            this._port = portMatch ? Number(portMatch[1]) : -1;
            this._path = match[3] || '';
            this._query = match[4] ? match[4].slice(1) : null;
            this._ref = match[5] ? match[5].slice(1) : null;
        }
        JavaURL.prototype.getProtocol = function () { return this._protocol; };
        JavaURL.prototype.getHost = function () { return this._host; };
        JavaURL.prototype.getPort = function () { return this._port; };
        JavaURL.prototype.getDefaultPort = function () { return this._protocol === 'https' ? 443 : (this._protocol === 'http' ? 80 : -1); };
        JavaURL.prototype.getAuthority = function () { return this._authority; };
        JavaURL.prototype.getPath = function () { return this._path; };
        JavaURL.prototype.getQuery = function () { return this._query; };
        JavaURL.prototype.getFile = function () { return this._path + (this._query == null ? '' : '?' + this._query); };
        JavaURL.prototype.getRef = function () { return this._ref; };
        JavaURL.prototype.toString = JavaURL.prototype.toExternalForm = function () { return this._text; };
        JavaURL.prototype.openConnection = function () { return new HttpURLConnection(this); };
        JavaURL.prototype.openStream = function () { return this.openConnection().getInputStream(); };

        // java.net.HttpURLConnection: the request goes out when the response is first asked
        // for, with whatever the source wrote to getOutputStream() as its body.
        function HttpURLConnection(url) {
            this._url = url; this._method = 'GET'; this._headers = {}; this._out = null; this._response = null;
        }
        HttpURLConnection.HTTP_OK = 200; HttpURLConnection.HTTP_CREATED = 201; HttpURLConnection.HTTP_NO_CONTENT = 204;
        HttpURLConnection.HTTP_MOVED_PERM = 301; HttpURLConnection.HTTP_MOVED_TEMP = 302; HttpURLConnection.HTTP_SEE_OTHER = 303;
        HttpURLConnection.HTTP_NOT_MODIFIED = 304; HttpURLConnection.HTTP_BAD_REQUEST = 400; HttpURLConnection.HTTP_UNAUTHORIZED = 401;
        HttpURLConnection.HTTP_FORBIDDEN = 403; HttpURLConnection.HTTP_NOT_FOUND = 404; HttpURLConnection.HTTP_INTERNAL_ERROR = 500;
        function headerKey(headers, name) {
            var lower = String(name).toLowerCase();
            for (var key in headers) if (key.toLowerCase() === lower) return key;
            return null;
        }
        HttpURLConnection.prototype.setRequestMethod = function (method) { this._method = String(method).toUpperCase(); };
        HttpURLConnection.prototype.getRequestMethod = function () { return this._method; };
        HttpURLConnection.prototype.setRequestProperty = function (name, value) {
            var existing = headerKey(this._headers, name);
            if (existing !== null) delete this._headers[existing];
            this._headers[String(name)] = String(value);
        };
        HttpURLConnection.prototype.addRequestProperty = function (name, value) {
            var existing = headerKey(this._headers, name);
            if (existing === null) this._headers[String(name)] = String(value);
            else this._headers[existing] += ', ' + String(value);
        };
        HttpURLConnection.prototype.getRequestProperty = function (name) {
            var existing = headerKey(this._headers, name);
            return existing === null ? null : this._headers[existing];
        };
        ['setDoInput', 'setDoOutput', 'setUseCaches', 'setConnectTimeout', 'setReadTimeout', 'setInstanceFollowRedirects',
         'setChunkedStreamingMode', 'setFixedLengthStreamingMode', 'setAllowUserInteraction', 'setIfModifiedSince',
         'setDefaultUseCaches', 'setHostnameVerifier', 'setSSLSocketFactory', 'connect', 'disconnect'].forEach(function (name) {
            HttpURLConnection.prototype[name] = function () {};
        });
        // Java turns a GET into a POST once its output stream is asked for.
        HttpURLConnection.prototype.getOutputStream = function () {
            if (!this._out) {
                if (this._method === 'GET') this._method = 'POST';
                this._out = new ByteArrayOutputStream();
            }
            return this._out;
        };
        HttpURLConnection.prototype._execute = function () {
            if (this._response) return this._response;
            var body = this._out ? this._out.toByteArray() : [];
            this._response = java.httpExecuteBytes(this._method, this._url.toString(), bytesToHex(body), this._headers);
            if (this._response.code() === 0) {
                var failed = this._response;
                this._response = null;
                throw new Error('java.io.IOException: no response from ' + this._url.toString() + ' ' + failed.message());
            }
            return this._response;
        };
        HttpURLConnection.prototype.getResponseCode = function () { return this._execute().code(); };
        HttpURLConnection.prototype.getResponseMessage = function () { return this._execute().message(); };
        HttpURLConnection.prototype.getInputStream = function () {
            var response = this._execute(), code = response.code();
            if (code >= 400) {
                var url = this._url.toString();
                throw new Error(code === 404 || code === 410
                    ? 'java.io.FileNotFoundException: ' + url
                    : 'java.io.IOException: Server returned HTTP response code: ' + code + ' for URL: ' + url);
            }
            return new ByteArrayInputStream(response.bodyBytes());
        };
        HttpURLConnection.prototype.getErrorStream = function () {
            var response = this._execute();
            return response.code() >= 400 ? new ByteArrayInputStream(response.bodyBytes()) : null;
        };
        // URLSession has already decoded a gzip / deflate / br body, so the bytes handed out
        // are no longer what Content-Encoding and Content-Length describe; Java's connection
        // does not decode, and a source that sees `gzip` wraps the stream in GZIPInputStream.
        HttpURLConnection.prototype._header = function (name) {
            var response = this._execute(), lower = String(name).toLowerCase();
            var decoded = response.header('Content-Encoding') !== null;
            if (decoded && (lower === 'content-encoding' || lower === 'content-length')) return null;
            return response.header(String(name));
        };
        HttpURLConnection.prototype.getHeaderField = function (name) {
            if (typeof name === 'number') {
                var keys = this.getHeaderFields().keySet();
                return name < keys.length ? this._header(keys[name]) : null;
            }
            return this._header(name);
        };
        HttpURLConnection.prototype.getHeaderFieldKey = function (n) {
            var keys = this.getHeaderFields().keySet();
            return n < keys.length ? keys[n] : null;
        };
        HttpURLConnection.prototype.getHeaderFields = function () {
            var headers = this._execute().headers(), out = __yueduJavaMap({}), self = this;
            headers.keySet().forEach(function (key) {
                var value = self._header(key);
                if (value !== null) out[key] = [value];
            });
            return out;
        };
        HttpURLConnection.prototype.getHeaderFieldInt = function (name, fallback) {
            var value = parseInt(this._header(name), 10);
            return isNaN(value) ? fallback : value;
        };
        HttpURLConnection.prototype.getContentType = function () { return this._header('Content-Type'); };
        HttpURLConnection.prototype.getContentEncoding = function () { return this._header('Content-Encoding'); };
        HttpURLConnection.prototype.getContentLength = HttpURLConnection.prototype.getContentLengthLong = function () {
            return this.getHeaderFieldInt('Content-Length', -1);
        };
        HttpURLConnection.prototype.getURL = function () { return this._url; };
        HttpURLConnection.prototype.getInstanceFollowRedirects = function () { return true; };

        function InetSocketAddress(host, port) {
            return {
                __host: String(host), __port: Number(port),
                getHostName: function () { return String(host); }, getHostString: function () { return String(host); },
                getPort: function () { return Number(port); }, toString: function () { return host + ':' + port; }
            };
        }
        function Socket(host, port) {
            this._connected = false;
            if (host != null && port != null) this.connect(InetSocketAddress(host, port), 0);
        }
        Socket.prototype.connect = function (address, timeout) {
            var ms = java.tcpConnectMillis(address.__host, address.__port, timeout == null ? 0 : Number(timeout));
            // Refused and timed out look alike from here; both are Java's IOException family.
            if (ms < 0) throw new Error('java.net.ConnectException: failed to connect to ' + address.toString());
            this._connected = true;
        };
        Socket.prototype.isConnected = function () { return this._connected; };
        Socket.prototype.isClosed = function () { return !this._connected; };
        Socket.prototype.setSoTimeout = Socket.prototype.setTcpNoDelay = Socket.prototype.setKeepAlive = function () {};
        Socket.prototype.close = function () { this._connected = false; };

        // ---- java.util / java.lang additions ----
        Arrays.copyOf = function (value, length) {
            var bytes = Array.prototype.slice.call(value.__bytes || value, 0, Number(length));
            while (bytes.length < Number(length)) bytes.push(0);
            return bytes;
        };
        Arrays.fill = function (array, a, b, c) {
            if (c === undefined) { for (var i = 0; i < array.length; i++) array[i] = a; return; }
            for (var k = Number(a); k < Number(b); k++) array[k] = c;
        };
        Arrays.equals = function (a, b) {
            if (a == null || b == null) return a === b;
            if (a.length !== b.length) return false;
            for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
            return true;
        };
        Arrays.toString = function (array) { return array == null ? 'null' : '[' + Array.prototype.join.call(array, ', ') + ']'; };
        Arrays.asList = function () { return Array.prototype.slice.call(arguments.length === 1 && Array.isArray(arguments[0]) ? arguments[0] : arguments); };
        System.arraycopy = function (src, srcPos, dest, destPos, length) {
            var copy = Array.prototype.slice.call(src, Number(srcPos), Number(srcPos) + Number(length));
            for (var i = 0; i < copy.length; i++) dest[Number(destPos) + i] = copy[i];
        };
        System.gc = function () {};
        System.lineSeparator = function () { return '\n'; };
        // One process-wide Properties map, as the JVM's: 洋柿子酱 takes a lock through
        // `getProperties().compute(key, fn)`, which runs fn and stores what it answers.
        var systemProperties = __yueduJavaMap({ 'line.separator': '\n', 'file.encoding': 'UTF-8', 'java.vendor': 'The Android Project' });
        Object.defineProperty(systemProperties, 'compute', {
            value: function (key, fn) {
                var previous = Object.prototype.hasOwnProperty.call(systemProperties, key) ? systemProperties[key] : null;
                var next = fn(key, previous);
                if (next == null) delete systemProperties[key]; else systemProperties[key] = next;
                return next == null ? null : next;
            },
            enumerable: false, configurable: true
        });
        Object.defineProperty(systemProperties, 'getProperty', {
            value: function (key, fallback) { var v = systemProperties.get(key); return v === null ? (fallback === undefined ? null : fallback) : v; },
            enumerable: false, configurable: true
        });
        Object.defineProperty(systemProperties, 'setProperty', {
            value: function (key, value) { var previous = systemProperties.get(key); systemProperties[key] = value; return previous; },
            enumerable: false, configurable: true
        });
        System.getProperties = function () { return systemProperties; };
        System.getProperty = function (key, fallback) { return systemProperties.getProperty(String(key), fallback); };
        System.setProperty = function (key, value) { return systemProperties.setProperty(String(key), String(value)); };

        // ---- Android / hutool / Legado helpers ----
        // android.webkit.CookieManager is the WebView's store; here the WebView and the HTTP
        // client share one store, which `cookie` (Legado's CookieStore) fronts.
        var CookieManager = {
            getInstance: function () {
                return {
                    getCookie: function (url) { var value = cookie.getCookie(String(url)); return value ? value : null; },
                    setCookie: function (url, value) { cookie.setCookie(String(url), String(value)); },
                    removeAllCookies: function () {}, removeSessionCookies: function () {},
                    flush: function () {}, setAcceptCookie: function () {}, acceptCookie: function () { return true; }
                };
            }
        };
        var LegadoCookieStore = {
            getCookie: function (url) { return cookie.getCookie(String(url)); },
            setCookie: function (url, value) { cookie.setCookie(String(url), String(value)); },
            replaceCookie: function (url, value) { cookie.replaceCookie(String(url), String(value)); },
            removeCookie: function (url) { cookie.removeCookie(String(url)); },
            getKey: function (url, key) { return cookie.getKey(String(url), String(key)); }
        };
        var HexUtil = {
            encodeHexStr: function (value, lower) {
                var hex = bytesToHex(typeof value === 'string' ? getBytes(value, 'UTF-8') : value);
                return lower === false ? hex.toUpperCase() : hex;
            },
            encodeHex: function (value) { return bytesToHex(value).split(''); },
            decodeHex: function (hex) { return javaBytes(hexToBytes(String(hex).replace(/\s+/g, ''))); },
            decodeHexStr: function (hex, charset) { return bytesToString(hexToBytes(String(hex)), charset || 'UTF-8'); }
        };

        // okhttp3.HttpUrl / Headers, for Request.Builder().url(httpUrl).headers(headers).
        function HttpUrl(text) { this._text = String(text); }
        HttpUrl.parse = HttpUrl.get = function (text) { return urlPattern.test(String(text)) ? new HttpUrl(text) : null; };
        HttpUrl.prototype.toString = function () { return this._text; };
        HttpUrl.prototype.newBuilder = function () {
            var text = this._text;
            var builder = {
                addQueryParameter: function (name, value) {
                    var hash = text.indexOf('#'), fragment = hash < 0 ? '' : text.slice(hash);
                    var base = hash < 0 ? text : text.slice(0, hash);
                    base += (base.indexOf('?') < 0 ? '?' : '&') + encodeURIComponent(String(name)) +
                        (value == null ? '' : '=' + encodeURIComponent(String(value)));
                    text = base + fragment;
                    return builder;
                },
                build: function () { return new HttpUrl(text); }
            };
            return builder;
        };
        function HeadersBuilder() { this._pairs = []; }
        HeadersBuilder.prototype.add = function (name, value) { this._pairs.push([String(name), String(value)]); return this; };
        HeadersBuilder.prototype.set = function (name, value) {
            var lower = String(name).toLowerCase();
            this._pairs = this._pairs.filter(function (pair) { return pair[0].toLowerCase() !== lower; });
            return this.add(name, value);
        };
        HeadersBuilder.prototype.build = function () { return { __pairs: this._pairs.slice() }; };
        var Headers = { Builder: HeadersBuilder };
        RequestBuilder.prototype.headers = function (headers) {
            var self = this;
            self._headers = {};
            (headers && headers.__pairs || []).forEach(function (pair) { self._headers[pair[0]] = pair[1]; });
            return self;
        };
        RequestBuilder.prototype.put = function (value) { this._method = 'PUT'; this._body = value || { body: '' }; return this; };
        RequestBuilder.prototype.patch = function (value) { this._method = 'PATCH'; this._body = value || { body: '' }; return this; };
        RequestBuilder.prototype['delete'] = function (value) { this._method = 'DELETE'; this._body = value || { body: '' }; return this; };
        OkHttpResponse.prototype.body = function () {
            var nativeResponse = this._native;
            return {
                string: function () { return nativeResponse.body(); },
                bytes: function () { return javaBytes(nativeResponse.bodyBytes()); },
                byteStream: function () { return new ByteArrayInputStream(nativeResponse.bodyBytes()); },
                close: function () {}
            };
        };
        DigestUtil.md5 = function (value) {
            return javaBytes(java.digestBytes(typeof value === 'string' || value instanceof String ? getBytes(String(value), 'UTF-8') : value, 'MD5'));
        };
        DigestUtil.sha256Hex = function (value) { return java.digestHex(String(value), 'SHA-256'); };
        DigestUtil.sha1Hex = function (value) { return java.digestHex(String(value), 'SHA-1'); };
    """#
}
