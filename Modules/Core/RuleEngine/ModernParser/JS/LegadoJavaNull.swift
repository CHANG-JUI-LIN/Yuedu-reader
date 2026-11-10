import JavaScriptCore

/// A nullable Java return value as a Legado script sees it.
///
/// JavaScriptCore hands a Swift `nil` returned from a `JSExport` method to JS as `undefined`;
/// Rhino hands Legado's Java `null` over as `null`. Scripts tell the two apart more often than
/// a loose `== null` suggests: `JSON.parse(cache.get(key))` is `null` under Legado and a
/// SyntaxError under `undefined` — G站漫画 (YCK1329) reads its saved headers exactly that way
/// on every search, before anything has been saved — `x === null` flips, and `'' + x` reads
/// "undefined". So every export whose Legado counterpart is declared nullable (`String?`, or a
/// `java.util.Map` lookup) answers through here; a Legado method that returns `""` for a missing
/// value (`java.get`) is not one of them.
///
/// The `JSValue` needs the calling script's context, so call this only from inside a JS call.
/// Each such export keeps a Swift-typed twin under the plain name for Swift callers, and the
/// export takes the JS name with `@objc(<selector>)`.
enum LegadoJavaNull {
    static func value(_ object: Any?) -> JSValue {
        let context = JSContext.current()
        guard let object else { return JSValue(nullIn: context) }
        return JSValue(object: object, in: context)
    }
}
