import CoreGraphics
import Foundation

/// The Phase 4E1 subset of CSS `text-indent`.
///
/// Keep unsupported authored values in the computed style instead of silently
/// dropping them: the layout capability scanner and the document admission
/// gate both consume this exact representation, so an unsupported declaration
/// can never leak into geometry as an accidental zero indent.
enum CSSTextIndent: Equatable {
    case length(CSSLength)
    case unsupported

    static let initial = CSSTextIndent.length(.px(0))

    /// Parses exactly one non-negative token from the Phase 4E1 subset:
    /// unitless zero, px, em, rem, or percentage. CSS-wide keywords and
    /// multi-token extensions (`hanging`, `each-line`) remain outside the gate.
    static func parse(_ raw: String) -> CSSTextIndent {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              value.split(whereSeparator: { $0.isWhitespace }).count == 1 else {
            return .unsupported
        }

        if let number = numericValue(value), number == 0,
           !value.contains(where: { $0.isLetter }),
           !value.hasSuffix("%") {
            return .length(.px(0))
        }

        let parsed: CSSLength?
        if value.hasSuffix("rem") {
            parsed = numericLength(value, suffixCount: 3, make: CSSLength.rem)
        } else if value.hasSuffix("px") {
            parsed = numericLength(value, suffixCount: 2, make: CSSLength.px)
        } else if value.hasSuffix("em") {
            parsed = numericLength(value, suffixCount: 2, make: CSSLength.em)
        } else if value.hasSuffix("%") {
            parsed = numericLength(value, suffixCount: 1) { .percent($0 / 100) }
        } else {
            parsed = nil
        }

        guard let parsed, parsed.nonNegativeMagnitude != nil else {
            return .unsupported
        }
        return .length(parsed)
    }

    var hasPositiveSpecifiedValue: Bool {
        guard case .length(let length) = self,
              let magnitude = length.nonNegativeMagnitude else {
            return false
        }
        return magnitude > 0
    }

    private static func numericValue(_ token: String) -> CGFloat? {
        guard let value = Double(token), value.isFinite else { return nil }
        return CGFloat(value)
    }

    private static func numericLength(
        _ token: String,
        suffixCount: Int,
        make: (CGFloat) -> CSSLength
    ) -> CSSLength? {
        let numberToken = String(token.dropLast(suffixCount))
        guard let value = numericValue(numberToken), value >= 0 else { return nil }
        return make(value)
    }
}

private extension CSSLength {
    var nonNegativeMagnitude: CGFloat? {
        let value: CGFloat
        switch self {
        case .px(let candidate), .pt(let candidate), .em(let candidate),
             .rem(let candidate), .percent(let candidate):
            value = candidate
        case .auto:
            return nil
        }
        return value >= 0 && value.isFinite ? value : nil
    }
}
