import Foundation
import UIKit

/// Applies the shared rule engine once to chapter text before shaping. Inline
/// element boundaries do not split regex matches. Paragraph separators exist
/// only in this evaluation string; persisted source offsets remain unchanged.
enum BrowserReaderTextStyling {
    private struct Piece {
        let range: NSRange
        let style: ComputedStyle
        let owner: ObjectIdentifier
        var isAttachment = false
    }

    static func prepare(root: BlockBox, sourceText: String, config: BrowserLayoutConfig) {
        guard config.regexHighlightConfiguration.isEnabled else { return }
        var pieces: [Piece] = []
        func collect(_ box: BlockBox) {
            for run in box.inlineRuns {
                if let ruby = run.ruby {
                    pieces += ruby.base.map {
                        Piece(range: $0.sourceRange, style: $0.style, owner: ObjectIdentifier(box))
                    }
                } else if run.atomic != nil {
                    pieces.append(Piece(range: run.sourceRange, style: run.style,
                                        owner: ObjectIdentifier(box), isAttachment: true))
                } else if run.sourceRange.length > 0 {
                    pieces.append(Piece(range: run.sourceRange, style: run.style, owner: ObjectIdentifier(box)))
                }
            }
            box.children.forEach(collect)
        }
        collect(root)
        pieces.sort {
            if $0.range.location == $1.range.location { return $0.isAttachment && !$1.isAttachment }
            return $0.range.location < $1.range.location
        }
        let source = sourceText as NSString
        let evaluated = NSMutableAttributedString()
        var mapped: [(source: NSRange, evaluation: NSRange)] = []
        var previousOwner: ObjectIdentifier?
        for piece in pieces {
            if let previousOwner, previousOwner != piece.owner {
                evaluated.append(NSAttributedString(string: "\n"))
            }
            if piece.isAttachment {
                evaluated.append(NSAttributedString(string: "\u{FFFC}"))
                previousOwner = piece.owner
                continue
            }
            let range = NSRange(location: evaluated.length, length: piece.range.length)
            evaluated.append(NSAttributedString(
                string: source.substring(with: piece.range),
                attributes: InlineLayout.textAttributes(for: piece.style, resolver: config.fontResolver)
            ))
            mapped.append((piece.range, range))
            previousOwner = piece.owner
        }
        do {
            let result = try RegexHighlightEngine.apply(
                configuration: config.regexHighlightConfiguration,
                appearance: config.readerStyleAppearance,
                assetRevision: config.readerStyleAssetRevision,
                to: evaluated
            )
            for diagnostic in result.diagnostics {
                AppLogger.render("browser regex highlight diagnostic", context: ["diagnostic": String(describing: diagnostic)])
            }
        } catch {
            AppLogger.render("browser regex highlight apply failed", context: ["error": String(describing: error)])
        }
        let styledSource = NSMutableAttributedString(string: sourceText)
        for mapping in mapped {
            evaluated.enumerateAttributes(in: mapping.evaluation) { attributes, range, _ in
                let target = NSRange(
                    location: mapping.source.location + range.location - mapping.evaluation.location,
                    length: range.length
                )
                styledSource.setAttributes(attributes, range: target)
            }
        }
        let snapshot = NSAttributedString(attributedString: styledSource)
        func install(_ box: BlockBox) {
            for index in box.inlineRuns.indices {
                box.inlineRuns[index].attributedSource = snapshot
            }
            box.children.forEach(install)
        }
        install(root)
    }
}
