import UIKit

/// 對齊: how body paragraphs that say nothing about alignment themselves are set.
///
/// It is the reader's default, not an override: an EPUB or a source page that writes its
/// own `text-align` keeps it, as does a title, a caption or a table cell.
enum ReaderBodyTextAlignment: String, Codable, CaseIterable, Sendable {
    /// 左右對齊: both edges line up. What every build before this setting did.
    case justified
    /// 靠起始側: lines end where their words end — ragged right in horizontal text,
    /// ragged bottom in vertical.
    case start

    var titleKey: String {
        switch self {
        case .justified: return "ReaderSettings.TextAlignment.Justified"
        case .start: return "ReaderSettings.TextAlignment.Start"
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .justified: return .justified
        case .start: return .natural
        }
    }
}

/// 段首縮排, in characters of the body size (em).
enum ReaderFirstLineIndent {
    /// Two characters: what TXT and online chapters were always set with.
    static let `default` = 2.0
    static let range: ClosedRange<Double> = 0...4
    static let step = 0.5

    /// A value from a file or another device, brought inside what the slider can show.
    static func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return `default` }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
