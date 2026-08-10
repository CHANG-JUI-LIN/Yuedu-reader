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
    /// Pre-fetches every image the chapter's DOM references — `<img src>` and
    /// the SVG-wrapped cover idiom — so the box tree can measure them through a
    /// synchronous loader. These are the only images layout NEEDS: a CSS
    /// background is paint-only and is fetched afterwards via `loadImage`, keyed
    /// by the source the computed style tree actually resolved.
    ///
    /// `renderWidth` is the content width the chapter lays out at; `data:` and
    /// remote sources go through `OnlineImageLoader`, which needs it to
    /// rasterize and downsample.
    func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage]

    /// Resolves ONE image source to bytes. Same routing as `prefetchImages`
    /// (publication resource / `data:` / remote), so a source fetched here and a
    /// source fetched there can never disagree.
    func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage?
    /// Resolves CSS font families (including registered @font-face families)
    /// to a concrete UIFont; nil falls back to UIFont(name:).
    func fontResolver() -> (([String], Int, Bool, CGFloat) -> UIFont?)?
}
