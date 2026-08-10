import CoreGraphics
import Foundation

/// One CSS length *value*. Percentages are kept symbolic (0…1) so the layout
/// stage can resolve them against the real containing-block width; `em`/`rem`
/// are resolved against font sizes at computed-value time.
enum CSSLength: Equatable {
    case px(CGFloat)
    case pt(CGFloat)
    case em(CGFloat)
    case rem(CGFloat)
    case percent(CGFloat)   // 0.0…1.0 of the containing block
    case auto
}

enum CSSLengthResolver {
    /// Parses a single CSS length token. Unsupported modern syntax
    /// (`calc()`, `min()`, `max()`, `clamp()`) returns nil → callers treat as
    /// the property's initial value. That is the intended Phase-1 behavior:
    /// authored `calc()` is *ignored*, never guessed.
    static func parse(_ raw: String) -> CSSLength? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s == "auto" { return .auto }
        switch s {
        case "0", "0.0": return .px(0)
        default: break
        }
        if s.hasSuffix("%") {
            guard let v = Double(s.dropLast()) else { return nil }
            return .percent(CGFloat(v) / 100)
        }
        if s.hasSuffix("px") {
            guard let v = Double(s.dropLast(2)) else { return nil }
            return .px(CGFloat(v))
        }
        if s.hasSuffix("pt") {
            guard let v = Double(s.dropLast(2)) else { return nil }
            return .pt(CGFloat(v))
        }
        if s.hasSuffix("rem") {
            guard let v = Double(s.dropLast(3)) else { return nil }
            return .rem(CGFloat(v))
        }
        if s.hasSuffix("em") {
            guard let v = Double(s.dropLast(2)) else { return nil }
            return .em(CGFloat(v))
        }
        if let v = Double(s) { return .px(CGFloat(v)) } // unitless → px
        return nil
    }

    /// Resolves a length to points against the given bases. Returns nil for `.auto`.
    /// `percentBase` is the containing-block width for margins/padding/width.
    static func resolve(_ length: CSSLength, emBase: CGFloat, remBase: CGFloat, percentBase: CGFloat) -> CGFloat? {
        switch length {
        case .px(let v): return v
        case .pt(let v): return v * 96.0 / 72.0
        case .em(let v): return v * emBase
        case .rem(let v): return v * remBase
        case .percent(let v): return v * percentBase
        case .auto: return nil
        }
    }
}
