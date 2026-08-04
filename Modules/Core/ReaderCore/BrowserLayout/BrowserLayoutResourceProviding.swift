import Foundation
import UIKit

/// What the browser-layout engine needs from a book. Implemented by an EPUB
/// adapter (Core layer); the engine never touches Readium or UI types.
protocol BrowserLayoutResourceProviding: AnyObject {
    var chapterCount: Int { get }
    func chapterTitle(at index: Int) -> String
    func chapterSourceHref(at index: Int) -> String?
    func chapterHTML(at index: Int) async throws -> String
    /// CSS ready for the browser engine: @imports inlined, @font-face stripped,
    /// url() rewritten to absolute publication URLs.
    func processedCSS(forChapter index: Int) async -> [String]
    /// Pre-fetches every `<img>` in the chapter; the engine consumes them via a
    /// synchronous loader during layout.
    func prefetchImages(forChapter index: Int, html: String) async -> [String: UIImage]
    /// Resolves CSS font families (including registered @font-face families)
    /// to a concrete UIFont; nil falls back to UIFont(name:).
    func fontResolver() -> (([String], Int, Bool, CGFloat) -> UIFont?)?
}
