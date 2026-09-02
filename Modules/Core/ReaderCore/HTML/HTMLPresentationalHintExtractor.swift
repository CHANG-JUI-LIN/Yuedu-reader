import CoreGraphics
import Foundation

/// Frontend-neutral HTML element semantics consumed by the presentational-hint
/// normalizer. A SwiftSoup node and a future Lexbor node both adapt into this
/// value; the extractor itself does not depend on either DOM implementation.
struct HTMLSemanticElement: Equatable {
    let tagName: String
    let attributes: [String: String]

    init(tagName: String, attributes: [String: String]) {
        self.tagName = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var normalized: [String: String] = [:]
        for key in attributes.keys.sorted() {
            normalized[key.lowercased()] = attributes[key]
        }
        self.attributes = normalized
    }

    func attribute(named name: String) -> String? {
        attributes[name.lowercased()]
    }
}

/// Parsed HTML dimension semantics. Percentages remain symbolic until layout
/// knows the containing inline size; integer-like legacy dimensions are CSS px.
enum HTMLPresentationalDimension: Equatable {
    case pixels(CGFloat)
    /// Fraction form: 15% is stored as 0.15.
    case percentage(CGFloat)

    static func parse(_ raw: String) -> HTMLPresentationalDimension? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasSuffix("%") {
            let number = String(value.dropLast())
            guard isASCIIUnsignedInteger(number),
                  let parsed = Double(number),
                  parsed.isFinite else { return nil }
            return .percentage(CGFloat(parsed / 100))
        }

        guard isASCIIUnsignedInteger(value),
              let parsed = Double(value),
              parsed.isFinite else { return nil }
        return .pixels(CGFloat(parsed))
    }

    private static func isASCIIUnsignedInteger(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x30 && scalar.value <= 0x39
        }
    }
}

enum HTMLPresentationalHintProperty: Equatable {
    case width
    case height
}

enum HTMLPresentationalHintValue: Equatable {
    case dimension(HTMLPresentationalDimension)
}

struct HTMLPresentationalHint: Equatable {
    let property: HTMLPresentationalHintProperty
    let value: HTMLPresentationalHintValue
}

/// Converts HTML markup presentation into typed declarations. These declarations
/// enter the author-presentational-hint origin: after UA defaults and before all
/// author CSS. No synthetic CSS text is constructed or reparsed.
enum HTMLPresentationalHintExtractor {
    static func extract(from element: HTMLSemanticElement) -> [HTMLPresentationalHint] {
        // Phase 4F0 is deliberately corpus-driven. The 23-book census found only
        // img width/height; table/body/alignment hints stay absent until real
        // coverage justifies their style and layout contracts.
        guard element.tagName == "img" else { return [] }

        var result: [HTMLPresentationalHint] = []
        if let raw = element.attribute(named: "width"),
           let dimension = HTMLPresentationalDimension.parse(raw) {
            result.append(HTMLPresentationalHint(
                property: .width,
                value: .dimension(dimension)
            ))
        }
        if let raw = element.attribute(named: "height"),
           let dimension = HTMLPresentationalDimension.parse(raw) {
            result.append(HTMLPresentationalHint(
                property: .height,
                value: .dimension(dimension)
            ))
        }
        return result
    }
}
