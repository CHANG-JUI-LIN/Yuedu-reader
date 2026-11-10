import Foundation
import ObjectiveC

/// JSON as Legado holds it. Its jayway JSONPath reads with json-smart's default provider
/// (`JsonSmartJsonProvider`, `MODE_PERMISSIVE`, `DEFAULT_ORDERED`): an object is a
/// `LinkedHashMap` in the order the text wrote its keys, an array a json-smart `JSONArray`.
/// Two things follow that sources depend on:
///
/// - **Order.** `$.*`, `$..key` and every list built from them come out in document order,
///   and so does an object's text. `JSONSerialization` keeps no order, so `parse(_:)` reads
///   the values with it and then records each object's key order from the same text.
/// - **Text.** An object reads as `LinkedHashMap.toString()` — `{id=12, name=…}`, strings
///   unquoted — not as JSON. 猫耳有声 takes an item's id with `String(result).match(/id=(\d+)/)`
///   and Lofter its cover with `result.match(/bigAvaImg=(.*?),/)`; JSON text matches neither,
///   and inside a JS string literal (`'{{$.postCount}}'`) its quotes are a SyntaxError.
///   An array reads as `JSONArray.toString()`, which is JSON text (`javaText(_:)`).
enum OrderedJSON {

    // MARK: Parse

    /// `text` parsed as `JSONSerialization` parses it (fragments allowed), with each object's
    /// key order recorded. Nil when the text is not JSON — for rule content that is an answer,
    /// not a failure: an HTML page is content too.
    static func parse(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.utf8.first else { return nil }
        let data = Data(trimmed.utf8)
        // Not JSON is a legitimate answer for rule content (an HTML page), so the parse error
        // carries nothing to log. A scalar needs no order, so only a container is scanned.
        guard let root = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return nil
        }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            recordKeyOrder(of: root, in: data)
        }
        return root
    }

    /// The entries of a JSON object in the order its text wrote them, or in the dictionary's
    /// own order for one no text describes (Legado's `HashMap` has none either). Nil when
    /// `value` is not a dictionary.
    static func entries(of value: Any) -> [(key: String, value: Any)]? {
        // An `Any` holding a parsed object hands back that same instance, recorded order and all.
        guard let dictionary = value as? NSDictionary else { return nil }
        if dictionary.count > 1,
           let order = objc_getAssociatedObject(dictionary, KeyOrder.associationKey) as? KeyOrder,
           order.keys.count == dictionary.count {
            var ordered: [(key: String, value: Any)] = []
            ordered.reserveCapacity(order.keys.count)
            for key in order.keys {
                guard let child = dictionary.object(forKey: key) else { break }
                ordered.append((key, child))
            }
            if ordered.count == dictionary.count { return ordered }
        }
        var unordered: [(key: String, value: Any)] = []
        unordered.reserveCapacity(dictionary.count)
        for (key, child) in dictionary {
            unordered.append(("\(key)", child))
        }
        return unordered
    }

    /// The values a JSON container holds, in order: an array's elements, an object's values.
    static func children(of value: Any) -> [Any] {
        if let entries = entries(of: value) { return entries.map(\.value) }
        if let array = value as? [Any] { return array }
        return []
    }

    // MARK: Text

    /// The value's `toString()` in Legado: a `LinkedHashMap` as `{key=value, …}`, nested maps
    /// the same way and nested arrays as their JSON text; a `JSONArray` as JSON text.
    static func javaText(_ value: Any) -> String {
        var out = ""
        appendJava(value, to: &out)
        return out
    }

    /// json-smart's `toJSONString()` (`JSONStyle.NO_COMPRESS`, the default): JSON text with
    /// keys in their recorded order. Nil for a value JSON cannot hold, such as a bridge object
    /// in a list a script built.
    static func jsonText(_ value: Any) -> String? {
        var out = ""
        return appendJSON(value, to: &out) ? out : nil
    }

    private static func appendJava(_ value: Any, to out: inout String) {
        if let string = value as? String {
            out += string
        } else if value is NSNull {
            out += "null"
        } else if let number = value as? NSNumber {
            out += javaNumber(number)
        } else if let entries = entries(of: value) {
            // `AbstractMap.toString()`.
            out += "{"
            for (index, entry) in entries.enumerated() {
                if index > 0 { out += ", " }
                out += entry.key
                out += "="
                appendJava(entry.value, to: &out)
            }
            out += "}"
        } else if value is [Any] {
            out += jsonText(value) ?? "\(value)"
        } else if let optional = value as? OptionalJSONValue {
            if let wrapped = optional.wrappedJSONValue { appendJava(wrapped, to: &out) } else { out += "null" }
        } else {
            out += "\(value)"
        }
    }

    private static func appendJSON(_ value: Any, to out: inout String) -> Bool {
        if let string = value as? String {
            appendQuoted(string, to: &out)
        } else if value is NSNull {
            out += "null"
        } else if let number = value as? NSNumber {
            if !isBoolean(number), !isIntegral(number), !number.doubleValue.isFinite { return false }
            out += javaNumber(number)
        } else if let entries = entries(of: value) {
            out += "{"
            for (index, entry) in entries.enumerated() {
                if index > 0 { out += "," }
                appendQuoted(entry.key, to: &out)
                out += ":"
                guard appendJSON(entry.value, to: &out) else { return false }
            }
            out += "}"
        } else if let array = value as? [Any] {
            out += "["
            for (index, element) in array.enumerated() {
                if index > 0 { out += "," }
                guard appendJSON(element, to: &out) else { return false }
            }
            out += "]"
        } else if let optional = value as? OptionalJSONValue {
            guard let wrapped = optional.wrappedJSONValue else { out += "null"; return true }
            return appendJSON(wrapped, to: &out)
        } else {
            return false
        }
        return true
    }

    /// json-smart's `JStylerObj.ESCAPE4Web`.
    private static func appendQuoted(_ string: String, to out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "/": out += "\\/"
            default:
                let v = scalar.value
                if v <= 0x1F || (0x7F...0x9F).contains(v) || (0x2000...0x20FF).contains(v) {
                    out += "\\u"
                    let hex = String(v, radix: 16, uppercase: true)
                    out += String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Numbers

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isIntegral(_ number: NSNumber) -> Bool {
        switch UInt8(bitPattern: number.objCType.pointee) {
        case UInt8(ascii: "c"), UInt8(ascii: "C"), UInt8(ascii: "s"), UInt8(ascii: "S"),
             UInt8(ascii: "i"), UInt8(ascii: "I"), UInt8(ascii: "l"), UInt8(ascii: "L"),
             UInt8(ascii: "q"), UInt8(ascii: "Q"):
            return true
        default:
            return false
        }
    }

    /// The number as Java prints what json-smart parsed: `Integer` / `Long` / `BigInteger`
    /// digits for an integer, `Double.toString` for a decimal (`9.0`, `1.5E-4`).
    private static func javaNumber(_ number: NSNumber) -> String {
        if isBoolean(number) { return number.boolValue ? "true" : "false" }
        if isIntegral(number) || number is NSDecimalNumber { return number.stringValue }
        return javaDouble(number.doubleValue)
    }

    /// Java's `Double.toString`: plain decimal with at least one fraction digit for
    /// 10⁻³ ≤ |d| < 10⁷, otherwise `d.dddE±n`, both with the shortest digits that round-trip.
    static func javaDouble(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        // Swift's description is the shortest round-tripping form, in either notation.
        let text = "\(magnitude)"
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        var whole = mantissa
        var fraction: Substring = ""
        if let dot = mantissa.firstIndex(of: ".") {
            whole = mantissa[..<dot]
            fraction = mantissa[mantissa.index(after: dot)...]
        }
        var digits = Array(whole + fraction)
        var point = whole.count + exponent
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" {
            digits.removeLast()
        }
        if magnitude >= 1e-3, magnitude < 1e7 {
            if point <= 0 {
                return sign + "0." + String(repeating: "0", count: -point) + String(digits)
            }
            if point >= digits.count {
                return sign + String(digits) + String(repeating: "0", count: point - digits.count) + ".0"
            }
            return sign + String(digits[..<point]) + "." + String(digits[point...])
        }
        let rest = digits.count > 1 ? String(digits[1...]) : "0"
        return sign + String(digits[0]) + "." + rest + "E" + String(point - 1)
    }

    // MARK: Key order

    /// An object's keys in text order, attached to the parsed dictionary.
    private final class KeyOrder {
        let keys: [String]
        init(_ keys: [String]) { self.keys = keys }

        /// The association needs an address that is stable and unique in the process: this
        /// class object's. Derived on each use, so there is no global mutable key variable.
        static var associationKey: UnsafeRawPointer {
            UnsafeRawPointer(Unmanaged.passUnretained(KeyOrder.self as AnyObject).toOpaque())
        }
    }

    /// Walks `data` alongside the tree `JSONSerialization` built from it and attaches each
    /// object's key order to its dictionary. Anything the walk cannot match keeps the
    /// dictionary's own order.
    private static func recordKeyOrder(of root: Any, in data: Data) {
        data.withUnsafeBytes { raw in
            var scanner = KeyOrderScanner(bytes: raw.bindMemory(to: UInt8.self))
            scanner.walk(root)
            if scanner.failed {
                AppLogger.parse("JSON key order not recorded; keys read in hash order", context: [
                    "offset": "\(scanner.index)", "length": "\(raw.count)",
                ], level: .anomaly)
            }
        }
    }

    private struct KeyOrderScanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        /// The text stopped matching JSON as this walk reads it. It never should:
        /// `JSONSerialization` accepted the same bytes.
        var failed = false

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            // A byte order mark `JSONSerialization` skips.
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
        }

        mutating func walk(_ value: Any?) {
            skipWhitespace()
            guard !failed, index < bytes.count else { return }
            switch bytes[index] {
            case UInt8(ascii: "{"): walkObject(value as? NSDictionary)
            case UInt8(ascii: "["): walkArray(value as? NSArray)
            case UInt8(ascii: "\""): _ = readString(keeping: false)
            default: skipScalar()
            }
        }

        private mutating func walkObject(_ dictionary: NSDictionary?) {
            index += 1
            let records = (dictionary?.count ?? 0) > 1
            var keys: [String] = []
            while !failed {
                skipWhitespace()
                guard index < bytes.count else { return fail() }
                if bytes[index] == UInt8(ascii: "}") { index += 1; break }
                guard bytes[index] == UInt8(ascii: "\"") else { return fail() }
                let key = readString(keeping: true)
                skipWhitespace()
                guard let key, index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return fail() }
                index += 1
                skipWhitespace()
                guard index < bytes.count else { return fail() }
                // Only a container has keys beneath it to record; a scalar is skipped unread.
                // A repeated key: the dictionary holds one of its values, and only an
                // occurrence whose keys match that value's records an order.
                switch bytes[index] {
                case UInt8(ascii: "{"), UInt8(ascii: "["): walk(dictionary?.object(forKey: key))
                default: walk(nil)
                }
                if records { keys.append(key) }
                skipWhitespace()
                guard index < bytes.count else { return fail() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; break }
                return fail()
            }
            guard records, !failed, let dictionary else { return }
            if keys.count != dictionary.count {
                // Repeated keys: each keeps its first position, as in a `LinkedHashMap`.
                var seen: Set<String> = []
                keys = keys.filter { seen.insert($0).inserted }
            }
            // `entries(of:)` checks each key against the dictionary when it reads the order.
            guard keys.count == dictionary.count else { return }
            objc_setAssociatedObject(dictionary, KeyOrder.associationKey, KeyOrder(keys),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        private mutating func walkArray(_ array: NSArray?) {
            index += 1
            var position = 0
            while !failed {
                skipWhitespace()
                guard index < bytes.count else { return fail() }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return }
                walk(array.flatMap { position < $0.count ? $0[position] : nil })
                position += 1
                skipWhitespace()
                guard index < bytes.count else { return fail() }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return }
                return fail()
            }
        }

        /// The string at `index` (an opening quote), decoded when `keeping`.
        private mutating func readString(keeping: Bool) -> String? {
            index += 1
            let start = index
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { break }
                if byte == UInt8(ascii: "\\") { escaped = true; index += 1 }
                index += 1
            }
            guard index < bytes.count else { fail(); return nil }
            let end = index
            index += 1
            guard keeping else { return "" }
            let slice = UnsafeBufferPointer(rebasing: bytes[start..<end])
            guard escaped else { return String(decoding: slice, as: UTF8.self) }
            // Escapes are rare in keys; let the JSON parser decode them exactly as it did.
            let quoted = UnsafeBufferPointer(rebasing: bytes[(start - 1)...end])
            guard let decoded = try? JSONSerialization.jsonObject(
                with: Data(buffer: quoted), options: .fragmentsAllowed) as? String else {
                fail()
                return nil
            }
            return decoded
        }

        private mutating func skipScalar() {
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"),
                     0x20, 0x09, 0x0A, 0x0D:
                    return
                default:
                    index += 1
                }
            }
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        private mutating func fail() {
            failed = true
        }
    }
}

/// An `Optional` erased to `Any`, as a list of regex groups holds them (`[String?]`); a
/// missing group is JSON's `null`, as `JSONSerialization` bridges it.
private protocol OptionalJSONValue {
    var wrappedJSONValue: Any? { get }
}

extension Optional: OptionalJSONValue {
    fileprivate var wrappedJSONValue: Any? { map { $0 } }
}
