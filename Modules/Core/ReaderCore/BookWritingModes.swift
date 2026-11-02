import Foundation
import YueduCoreText

/// Which way a book reads: a property of the book, fixed for the session.
///
/// It used to share one bit (`isVerticalEPUB`) with every document's writing mode, decided once per
/// book. A Calibre conversion of a vertical book appends a table of contents that declares no writing
/// mode, and it was laid out vertically. The two answers separate here: `BookDirection` belongs to the
/// book, `BookWritingModes.writingMode(forSpine:)` to one document.
struct BookDirection: Equatable, Sendable {
    /// Page order, the spine's side, which edge is "next", spread order, the opening animation.
    let isRTL: Bool
    /// The mode of the book's leading documents: what book-level UI that is not a page shows (the
    /// table-of-contents sheet, the settings panel).
    let principalMode: ReaderWritingMode

    /// A book laid out in the user's 排版方向 reads in that mode's direction.
    init(uniform mode: ReaderWritingMode) {
        self.init(isRTL: mode.isVertical, principalMode: mode)
    }

    init(isRTL: Bool, principalMode: ReaderWritingMode) {
        self.isRTL = isRTL
        self.principalMode = principalMode
    }
}

/// What a publisher EPUB's package says about writing modes before any document is parsed, and the
/// rules that turn it, with each document's own declaration, into writing modes and a direction.
/// A pure function of the book's files: never of which chapters happen to have been laid out.
struct BookWritingModeFacts: Equatable, Sendable {
    /// The OPF's `primary-writing-mode`, else `.verticalRL` inferred from `page-progression-direction="rtl"`
    /// with a language that is not an RTL script (`PublicationSession.parseOPFMetadataXML`).
    let opfWritingMode: EPUBWritingMode
    let pageProgression: EPUBPageProgressionDirection
    /// A `writing-mode` declaration of any value, under any selector, in a manifest stylesheet or in one
    /// of the first three linear spine documents.
    let declaresWritingModeInCSS: Bool
    /// The first three linear spine documents, whose declarations decide `principalMode`.
    let leadingDocumentHrefs: [String]

    /// The mode of a document that declares none. When the book's CSS declares writing modes, an
    /// undeclared document has CSS's initial value, horizontal, as WebKit, Readest and Apple Books lay it
    /// out. When it declares none at all, the OPF is the only signal there is: a book vertical only by its
    /// OPF stays vertical (maintainer, 2026-11-02).
    var bookDefault: ReaderWritingMode {
        if declaresWritingModeInCSS { return .horizontal }
        return opfWritingMode == .verticalRL ? .verticalRTL : .horizontal
    }

    /// Rule 1's scan: a `writing-mode` declaration, or its `-webkit-` / `-epub-` alias, of any value under
    /// any selector. Comments are not declarations.
    static func containsWritingModeDeclaration(in source: String) -> Bool {
        let uncommented = source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        return uncommented.range(of: #"(^|[;\s{"'])(-epub-|-webkit-)?writing-mode\s*:"#,
                                 options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether `source` names the property at all, in a declaration, a comment or anywhere else: what a
    /// document must contain to declare a mode, cheap enough to ask of every chapter before parsing it.
    static func mentionsWritingMode(_ source: String) -> Bool {
        source.range(of: "writing-mode", options: [.caseInsensitive, .literal]) != nil
    }

    func writingMode(declared: ReaderWritingMode?) -> ReaderWritingMode {
        declared ?? bookDefault
    }

    /// `leadingDeclared` are the declarations of `leadingDocumentHrefs`, in spine order. Page order is the
    /// OPF's `page-progression-direction` when it declares one, otherwise the leading documents' mode's:
    /// entering a horizontal chapter of a vertical book never reverses page turning (maintainer,
    /// 2026-11-02, as Apple Books and Readest page it).
    func direction(leadingDeclared: [ReaderWritingMode?]) -> BookDirection {
        let principal = leadingDeclared.lazy.compactMap { $0 }.first ?? bookDefault
        let isRTL: Bool
        switch pageProgression {
        case .rtl: isRTL = true
        case .ltr: isRTL = false
        case .default: isRTL = principal.isVertical
        }
        return BookDirection(isRTL: isRTL, principalMode: principal)
    }
}

/// The one answer to "which way does this book read" and "which writing mode is spine *n* laid out in",
/// for every caller: both engines, paged and scroll, the shelf's opening animation, `ReaderView`.
///
/// A document's mode is its principal writing mode (CSS Writing Modes 3 §8: `<body>`'s `writing-mode`,
/// inherited from `<html>`), read by the engine package from the same cascade the browser engine lays the
/// document out with, else the book's default. Resolved lazily, once per spine; it depends on no reader
/// setting, so a font or margin change never asks again.
@MainActor
final class BookWritingModes {
    /// A chapter's markup with the stylesheets it uses, as the browser engine ingests them.
    typealias StyleInput = @MainActor (Int) async throws -> CSSFrontendInput

    let direction: BookDirection
    private let facts: BookWritingModeFacts?
    private let styleInput: StyleInput?
    private var resolved: [Int: ReaderWritingMode] = [:]
    private var pending: [Int: Task<ReaderWritingMode, Never>] = [:]

    /// A book laid out in the user's 排版方向 (TXT, online, Aozora): every document in `mode`.
    init(uniform mode: ReaderWritingMode) {
        direction = BookDirection(uniform: mode)
        facts = nil
        styleInput = nil
    }

    private init(facts: BookWritingModeFacts, direction: BookDirection, resolved: [Int: ReaderWritingMode],
                 styleInput: @escaping StyleInput) {
        self.facts = facts
        self.direction = direction
        self.resolved = resolved
        self.styleInput = styleInput
    }

    /// A publisher EPUB. Parses the leading documents, which decide the direction; every other document
    /// is parsed when it is first asked for. When the book declares no writing mode (rule 1's scan read
    /// every manifest stylesheet and the leading documents themselves, and found none), the leading
    /// documents declare nothing by construction and are not read again.
    static func resolve(facts: BookWritingModeFacts, spineIndex: (String) -> Int?,
                        styleInput: @escaping StyleInput) async -> BookWritingModes {
        var resolved: [Int: ReaderWritingMode] = [:]
        var leading: [ReaderWritingMode?] = []
        for href in facts.leadingDocumentHrefs where facts.declaresWritingModeInCSS {
            guard let spine = spineIndex(href) else {
                AppLogger.parse("Writing mode: a leading spine document is not in the reading order", context: [
                    "href": href,
                ])
                continue
            }
            let declared = await declaredMode(spine: spine, styleInput: styleInput)
            resolved[spine] = facts.writingMode(declared: declared)
            leading.append(declared)
        }
        return BookWritingModes(facts: facts, direction: facts.direction(leadingDeclared: leading),
                                resolved: resolved, styleInput: styleInput)
    }

    /// The mode spine `spine` is laid out in.
    func writingMode(forSpine spine: Int) async -> ReaderWritingMode {
        guard let facts, let styleInput else { return direction.principalMode }
        if let mode = resolved[spine] { return mode }
        if let task = pending[spine] { return await task.value }
        let task = Task { @MainActor in
            facts.writingMode(declared: await Self.declaredMode(spine: spine, styleInput: styleInput))
        }
        pending[spine] = task
        let mode = await task.value
        resolved[spine] = mode
        pending[spine] = nil
        return mode
    }

    /// The mode of a spine already resolved, for a caller that cannot wait; `nil` until it is.
    func cachedWritingMode(forSpine spine: Int) -> ReaderWritingMode? {
        facts == nil ? direction.principalMode : resolved[spine]
    }

    /// `nil` when the document declares no writing mode. A document whose markup or stylesheets cannot be
    /// read or parsed takes the book's default: the browser engine refuses it too (`chapterParse`) and the
    /// legacy engine lays it out in the mode given. Logged; removable if the package ever parses every
    /// document.
    ///
    /// A document none of whose texts names the property declares nothing, so it is not parsed: most books
    /// never write `writing-mode`, and the parse costs tens of milliseconds a chapter. The texts are the
    /// ones the parse reads, its markup (inline `style` and `<style>`) and `productionStylesheetTexts`,
    /// into which ingestion has already inlined every `@import`.
    private static func declaredMode(spine: Int, styleInput: StyleInput) async -> ReaderWritingMode? {
        let start = SourcePerfTrace.now
        defer { SourcePerfTrace.record("chapter.writingMode", "spine=\(spine)", since: start, thresholdMs: 0) }
        do {
            let input = try await styleInput(spine)
            guard ([input.html] + input.productionStylesheetTexts)
                .contains(where: BookWritingModeFacts.mentionsWritingMode) else { return nil }
            return try await principalWritingMode(of: input)
        } catch {
            AppLogger.parse("Writing mode: the chapter could not be parsed; it takes the book's default",
                            context: ["spine": spine, "error": String(describing: error)])
            return nil
        }
    }

    /// Off the main actor: the parse and the read both walk the document.
    nonisolated private static func principalWritingMode(of input: CSSFrontendInput) async throws -> ReaderWritingMode? {
        try await BrowserChapterDocument.parse(input: input).principalWritingMode
    }
}

extension BookWritingModes {
    /// A publisher EPUB in the reader: its documents read through the browser engine's ingestion, so the
    /// mode is decided from the stylesheets the chapter is laid out with. A chapter admission has already
    /// ingested is not read again (reading one costs ~20 ms in a 2,000-chapter book).
    static func resolve(session: PublicationSession,
                        resource: EPUBBrowserLayoutResourceAdapter) async -> BookWritingModes {
        await resolve(facts: await session.writingModeFacts(), spineIndex: { session.chapterIndex(for: $0) },
                      styleInput: { spine in
                          if let ingested = resource.ingestedCSSFrontendInput(forChapter: spine) { return ingested }
                          return await resource.cssFrontendInput(forChapter: spine,
                                                                 html: try await resource.chapterHTML(at: spine))
                      })
    }
}
