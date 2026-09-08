import Foundation

/// Task 6 value frontend. ComputedStyle mapping is deliberately added in Task
/// 7; this type owns only Lexbor DOM/cascade evaluation and pointer copying.
final class LexborCSSFrontend {
    private let owner: LexborDocumentOwner

    init(input: CSSFrontendInput) throws {
        owner = try LexborDocumentOwner(html: input.html)
    }

    func snapshot(input: CSSFrontendInput) throws -> LexborFrontendSnapshot {
        try LexborHTMLSemanticAdapter.snapshot(owner: owner, input: input)
    }
}
