import Foundation
import SwiftSoup

/// EPUB semantic ingestion, before either CSS frontend. Resource bytes and
/// import/font processing remain owned by BookResourceProvider/EPUBStyleResolver.
@MainActor
enum EPUBStylesheetIngestion {
    static func collect(
        html: String, chapterHref: String,
        resourceProvider: any BookResourceProvider, styleResolver: EPUBStyleResolver
    ) async -> CSSFrontendInput {
        var sheets: [AuthorStylesheet] = []
        var diagnostics: [CSSFrontendDiagnostic] = []
        func report(_ message: String, order: Int, label: String) {
            diagnostics.append(CSSFrontendDiagnostic(
                stage: .ingestion, stylesheet: StylesheetIdentity(sourceOrder: order, label: label),
                semanticPath: nil, property: nil, message: message
            ))
        }
        do {
            let document = try SwiftSoup.parse(html)
            let head = document.head()
            let nodes = try head?.select("link, style").array() ?? []
            var linkedHrefs = resourceProvider.cssResourceHrefs()
            for link in try head?.select("link[rel=stylesheet]").array() ?? [] {
                let href = try link.attr("href")
                guard !href.isEmpty else { continue }
                let resolved = EPUBStyleResolver.resolveCSSHref(href, cssHref: "", chapterHref: chapterHref)
                if !linkedHrefs.contains(resolved) { linkedHrefs.append(resolved) }
            }

            // Capture the exact old processedCSS array before authored-node
            // processing. Remove this replay only after Current is retired.
            func appendCompatibility(_ text: String, source: AuthorStylesheet.Source) {
                guard !text.isEmpty else { return }
                sheets.append(AuthorStylesheet(
                    source: source, text: text, sourceOrder: sheets.count,
                    currentCompatibilityOrder: sheets.count, currentCompatibilityOnly: true,
                    media: nil, isAlternate: false
                ))
            }
            for (ordinal, node) in nodes.enumerated() where node.tagName() == "style" {
                let raw = try node.html()
                guard !raw.isEmpty else { continue }
                let processed = await styleResolver.processStylesheet(raw, cssHref: "", chapterHref: chapterHref)
                appendCompatibility(processed, source: .inline(nodeOrdinal: ordinal))
            }
            // Per-collection memo avoids reading a linked resource twice for
            // the two order projections; the adapter owns the chapter cache.
            var linkedResults: [String: EPUBStyleResolver.ProcessedStylesheet] = [:]
            var loadFailures: [String: String] = [:]
            func load(_ href: String) async -> EPUBStyleResolver.ProcessedStylesheet? {
                if let result = linkedResults[href] { return result }
                if loadFailures[href] != nil { return nil }
                do {
                    let response = try await resourceProvider.response(for: resourceProvider.resourceURL(for: href))
                    guard let raw = String(data: response.data, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    let result = await styleResolver.processStylesheetResult(raw, cssHref: href, chapterHref: chapterHref)
                    linkedResults[href] = result
                    return result
                } catch {
                    let message = "stylesheet load failed: \(href): \(error)"
                    loadFailures[href] = message
                    AppLogger.parse("[EPUBStylesheetIngestion] \(message)")
                    return nil
                }
            }
            for href in linkedHrefs {
                if let result = await load(href) {
                    appendCompatibility(result.text, source: .linked(href: href))
                }
            }

            for (ordinal, node) in nodes.enumerated() {
                let source: AuthorStylesheet.Source
                let result: EPUBStyleResolver.ProcessedStylesheet?
                let label: String
                var alternate = false
                if node.tagName() == "style" {
                    source = .inline(nodeOrdinal: ordinal)
                    label = "\(chapterHref)#style[\(ordinal)]"
                    result = await styleResolver.processStylesheetResult(
                        try node.html(), cssHref: "", chapterHref: chapterHref, cacheIdentity: label
                    )
                } else {
                    let rel = try node.attr("rel").lowercased().split(whereSeparator: { $0.isWhitespace })
                    guard rel.contains("stylesheet") else { continue }
                    alternate = rel.contains("alternate")
                    let href = try node.attr("href")
                    guard !href.isEmpty else {
                        report("stylesheet load failed: empty href", order: ordinal, label: chapterHref)
                        continue
                    }
                    label = EPUBStyleResolver.resolveCSSHref(href, cssHref: "", chapterHref: chapterHref)
                    source = .linked(href: label)
                    result = await load(label)
                    if let failure = loadFailures[label] { report(failure, order: ordinal, label: label) }
                }
                let media = try node.hasAttr("media") ? node.attr("media") : nil
                let sheet = AuthorStylesheet(
                    source: source, text: result?.text ?? "", sourceOrder: ordinal,
                    currentCompatibilityOrder: nil, currentCompatibilityOnly: false,
                    media: media, isAlternate: alternate
                )
                sheets.append(sheet)
                if !sheet.hasSupportedMedia { report("unsupported media: \(media ?? "")", order: ordinal, label: label) }
                if alternate { report("inactive alternate stylesheet", order: ordinal, label: label) }
                for message in result?.diagnostics ?? [] { report(message, order: ordinal, label: label) }
            }
            await styleResolver.registerAllPendingFontFaces()
        } catch {
            AppLogger.parse("[EPUBStylesheetIngestion] HTML collection failed: \(error)")
            report("HTML collection failed: \(error)", order: 0, label: chapterHref)
        }
        return CSSFrontendInput(html: html, stylesheets: sheets, diagnostics: diagnostics)
    }
}
