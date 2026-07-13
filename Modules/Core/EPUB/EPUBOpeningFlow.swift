import Foundation

/// Lightweight publication direction used before the full reader session is
/// opened, so a bookshelf card can unfold around the correct physical spine.
struct EPUBOpeningFlow: Equatable, Sendable {
    let isVertical: Bool
    let pageProgressionIsRTL: Bool

    static func containsVerticalWritingModeDeclaration(in source: String) -> Bool {
        let patterns = [
            #"-epub-writing-mode\s*:\s*vertical-rl"#,
            #"-webkit-writing-mode\s*:\s*vertical-rl"#,
            #"(^|[;\s{\"'])writing-mode\s*:\s*vertical-rl"#,
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { return false }
            return regex.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            ) != nil
        }
    }
}
