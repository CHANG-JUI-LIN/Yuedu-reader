//
//  yuedu_appTests.swift
//  yuedu appTests
//
//  Created by 張瑞麟 on 2026/2/27.
//

import Testing
import Foundation
import CoreText
import UIKit
@testable import yuedu_app

struct yuedu_appTests {
    private let testEPUBPath = "/Users/zhangruilin/Library/Mobile Documents/com~apple~CloudDocs/被讨厌的勇气：“自我启发之父”阿德勒的哲学课 = 嫌われる勇気：自己啓発の源流「アドラー」の教え ([日] 岸见一郎，[日] 古贺史健 著；渠海霞 译) (z-library.sk, 1lib.sk, z-lib.sk).epub"
    private let testBookSourcePath = "/Users/zhangruilin/Library/Mobile Documents/com~apple~CloudDocs/书源(856)-已测试并去重.json"

    private var hasBookSourceFixture: Bool {
        FileManager.default.fileExists(atPath: testBookSourcePath)
    }

    private var testEPUBURL: URL? {
        let url = URL(fileURLWithPath: testEPUBPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func colorsApproximatelyEqual(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
              rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        else {
            return lhs == rhs
        }
        return abs(lr - rr) <= 0.01
            && abs(lg - rg) <= 0.01
            && abs(lb - rb) <= 0.01
            && abs(la - ra) <= 0.01
    }

    private func imageAttachments(
        in layout: CoreTextPaginator.ChapterLayout,
        pageIndex: Int
    ) -> [CoreTextPaginator.RenderedAttachment] {
        (layout.inlineAttachments[pageIndex] ?? [])
            + (layout.blockAttachments[pageIndex] ?? [])
            + (layout.blockRenderables[pageIndex] ?? []).compactMap(\.imageAttachment)
    }

    private func loadSource(named name: String) throws -> BookSource {
        let json = try String(contentsOfFile: testBookSourcePath, encoding: .utf8)
        let sources = try JSONDecoder().decode([BookSource].self, from: Data(json.utf8))
        return try #require(sources.first(where: { $0.bookSourceName == name }))
    }

    private func makeChapterLayout(
        text: String,
        pageStarts: [Int]
    ) -> CoreTextPaginator.ChapterLayout {
        let attributedString = NSAttributedString(string: text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let ranges = pageStarts.enumerated().map { index, start in
            let end = index + 1 < pageStarts.count ? pageStarts[index + 1] : attributedString.length
            return CFRangeMake(start, max(0, end - start))
        }

        return CoreTextPaginator.ChapterLayout(
            spineIndex: 0,
            attributedString: attributedString,
            framesetter: framesetter,
            pageRanges: ranges,
            inlineAttachments: [:],
            inlineAnnotations: [:],
            blockAttachments: [:],
            blockRenderables: [:],
            pageKinds: Array(repeating: .text, count: max(ranges.count, 1)),
            pageBackgroundImage: nil,
            anchorOffsets: [:],
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            backgroundColor: .systemBackground,
            contentInsets: .zero
        )
    }

    private struct ProgressFallbackBuilder: AttributedStringBuilding {
        let chapterCount: Int

        func chapterTitle(at index: Int) -> String { "c\(index)" }
        func chapterSourceHref(at index: Int) -> String? { String(index) }
        func chapterDataSize(at index: Int) async -> Int { 0 }
        func chapterIndex(for href: String) -> Int? { Int(href) }
        func cssResourceHrefs() -> [String] { [] }

        func buildChapter(
            at index: Int,
            settings: ReaderRenderSettings,
            themeTextColor: UIColor,
            themeBackgroundColor: UIColor
        ) async throws -> AttributedChapterBuildResult {
            let attributed = NSAttributedString(
                string: "chapter \(index)",
                attributes: [.font: UIFont.systemFont(ofSize: settings.fontSize)]
            )
            return AttributedChapterBuildResult(
                attributedString: attributed,
                imagePage: nil,
                pageBackgroundImage: nil,
                anchorOffsets: [:]
            )
        }
    }

    private actor ProgressiveTOCGate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class ProgressiveTOCFetcher: BookSourceFetching {
        let source: BookSource
        let firstPageChapters: [OnlineChapterRef]
        let finalPackage: TOCPackage
        let gate = ProgressiveTOCGate()

        init(source: BookSource, firstPageChapters: [OnlineChapterRef], finalPackage: TOCPackage) {
            self.source = source
            self.firstPageChapters = firstPageChapters
            self.finalPackage = finalPackage
        }

        func fetchBookInfoPackage(
            url: String,
            source: BookSource,
            runtimeVariables: [String: String]?
        ) async throws -> BookInfoPackage {
            throw NSError(domain: "ProgressiveTOCFetcher", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fetchBookInfoPackage should not be called in this test"
            ])
        }

        func fetchTOCPackage(
            tocUrl: String,
            source: BookSource,
            runtimeVariables: [String: String]?,
            onFirstPageReady: (([OnlineChapterRef]) -> Void)?
        ) async throws -> TOCPackage {
            #expect(source.id == self.source.id)
            #expect(tocUrl == finalPackage.tocURL)
            onFirstPageReady?(firstPageChapters)
            await gate.wait()
            return finalPackage
        }

        func isChapterCached(
            bookId: UUID,
            chapterIndex: Int,
            expectedSourceURL: String?,
            expectedTOCTitle: String?
        ) -> Bool {
            false
        }

        func clearChapterCache(bookId: UUID, chapterIndex: Int) {}

        func clearAllChapterCache(bookId: UUID) {}

        func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }

        func loadChapterPackageSync(
            bookId: UUID,
            chapterIndex: Int,
            expectedSourceURL: String?,
            expectedTOCTitle: String?
        ) -> ChapterPackage? {
            nil
        }

        func loadNormalizedChapterHTMLSync(
            bookId: UUID,
            chapterIndex: Int,
            expectedSourceURL: String?,
            expectedTOCTitle: String?
        ) -> String? {
            nil
        }
    }

    private final class StubPaginatedURLProtocol: URLProtocol {
        static var htmlByURL: [String: String] = [:]
        static var blockingURL: String?
        static var beforeRespond: ((String) -> Void)?
        static var blockSemaphore = DispatchSemaphore(value: 0)

        static func reset() {
            htmlByURL = [:]
            blockingURL = nil
            beforeRespond = nil
            blockSemaphore = DispatchSemaphore(value: 0)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url?.absoluteString,
                  let html = Self.htmlByURL[url],
                  let responseURL = request.url else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            Self.beforeRespond?(url)
            if url == Self.blockingURL {
                Self.blockSemaphore.wait()
            }

            let response = HTTPURLResponse(
                url: responseURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func fetchFirstChapter(sourceName: String, keyword: String, expectedTitle: String) async throws
        -> ChapterPackage
    {
        let source = try loadSource(named: sourceName)
        let books = try await BookSourceFetcher.shared.search(query: keyword, in: source)
        let exactMatch = books.first(where: { $0.name == expectedTitle })
        let partialMatch = books.first(where: { $0.name.contains(expectedTitle) })
        let book = try #require(exactMatch ?? partialMatch)
        let info = try await BookSourceFetcher.shared.fetchBookInfo(
            url: book.bookUrl,
            source: source,
            runtimeVariables: book.runtimeVariables
        )
        let tocUrl = info.tocUrl.isEmpty ? book.bookUrl : info.tocUrl
        let chapters = try await BookSourceFetcher.shared.fetchTOC(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: info.runtimeVariables
        )
        let first = try #require(chapters.first)
        return try await BookSourceFetcher.shared.fetchChapterPackage(
            ref: first,
            bookId: UUID(),
            source: source,
            chapterReferer: tocUrl
        )
    }

    @Test @MainActor func onlineCoordinatorUsesCachedChapterAndPlaceholder() async throws {
        let book = ReadingBook(title: "線上書", author: "作者", source: "https://example.com", contentFilename: "")
        let bookId = book.id
        let refs = [
            OnlineChapterRef(index: 0, title: "章一", url: "https://example.com/1"),
            OnlineChapterRef(index: 1, title: "章二", url: "https://example.com/2"),
        ]
        var onlineBook = book
        onlineBook.isOnline = true
        onlineBook.onlineChapters = refs

        _ = BookSourceFetcher.shared.saveToCache(
            content: "已快取內容",
            bookId: bookId,
            chapterIndex: 0,
            sourceURL: refs[0].url,
            tocTitle: refs[0].title
        )

        let package = try OnlineBookCoordinator.shared.buildPackage(for: onlineBook, preferredChapter: 1)

        #expect(package.parsedBook.chapters.count == 2)
        #expect(package.parsedBook.chapters[0].html.contains("已快取內容"))
        #expect(package.parsedBook.chapters[1].html.contains("載入章節中…"))

        BookSourceFetcher.shared.clearAllChapterCache(bookId: bookId)
    }

    @Test func readerLocatorRoundTripsAndSupportsLegacyKeys() throws {
        let locator = ReaderLocator(
            spineHref: "Text/chapter-3.xhtml",
            chapterIndex: 2,
            pageInChapter: 4,
            totalPagesInChapter: 9,
            globalPage: 18,
            progression: 0.42,
            generationId: 7,
            title: "第三章",
            chapterProgression: 0.5,
            totalProgression: 0.42,
            locatorJSON: "{\"href\":\"Text/chapter-3.xhtml\"}",
            cssSelector: "#p-12",
            partialCFI: "/4/2[p12]",
            domRangeJSON: "{\"start\":12}",
            highlightedText: "測試段落",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(locator)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReaderLocator.self, from: data)

        #expect(decoded == locator)

        let legacyJSON = """
        {
          "href": "Text/legacy.xhtml",
          "position": 3,
          "spineIndex": 1
        }
        """
        let legacy = try decoder.decode(ReaderLocator.self, from: Data(legacyJSON.utf8))
        #expect(legacy.spineHref == "Text/legacy.xhtml")
        #expect(legacy.chapterIndex == 1)
        #expect(legacy.pageInChapter == 3)
        #expect(legacy.totalPagesInChapter == 1)
    }

    @Test func suduguSourceCanFetchFirstChapterEndToEnd() async throws {
        guard hasBookSourceFixture else { return }
        let package = try await fetchFirstChapter(
            sourceName: "速读谷",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
        #expect(package.content.contains("巴蜀"))
    }

    @Test func sixtyNineBookBarCanFetchFirstChapterEndToEnd() async throws {
        guard hasBookSourceFixture else { return }
        let package = try await fetchFirstChapter(
            sourceName: "69书吧👌",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
    }

    @Test func aiKanShuBaCanFetchFirstChapterEndToEnd() async throws {
        guard hasBookSourceFixture else { return }
        let package = try await fetchFirstChapter(
            sourceName: "爱看书吧",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
    }

    @Test func tuJiuSanCanFetchFirstChapterEndToEnd() async throws {
        guard hasBookSourceFixture else { return }
        let package = try await fetchFirstChapter(
            sourceName: "兔九三🐰",
            keyword: "斗罗大陆",
            expectedTitle: "斗罗大陆"
        )
        #expect(!package.content.isEmpty)
    }

    @Test func charOffsetStoreRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CharOffsetStoreTest-\(UUID().uuidString)")
        let store = CharOffsetStore(directoryURL: dir)
        let record = CharOffsetRecord(
            bookId: "book-abc",
            spineIndex: 3,
            charOffset: 1024,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.save(record)
        store.flushSync()

        let loaded = store.load(bookId: "book-abc")
        #expect(loaded?.spineIndex == 3)
        #expect(loaded?.charOffset == 1024)
    }

    @Test func charOffsetStoreReturnsNilForUnknownBook() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CharOffsetStoreTest-\(UUID().uuidString)")
        let store = CharOffsetStore(directoryURL: dir)
        #expect(store.load(bookId: "unknown") == nil)
    }

    @Test func charOffsetStoreSupportsBookIdWithSlashes() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CharOffsetStoreTest-\(UUID().uuidString)")
        let store = CharOffsetStore(directoryURL: dir)
        let record = CharOffsetRecord(
            bookId: "/var/mobile/Documents/book.epub",
            spineIndex: 1,
            charOffset: 42,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100)
        )
        store.save(record)
        store.flushSync()
        let loaded = store.load(bookId: record.bookId)
        #expect(loaded == record)
    }

    @Test func coreTextReadingPositionMapsToCurrentOffsets() {
        let layouts: [Int: CoreTextPaginator.ChapterLayout] = [
            0: makeChapterLayout(text: "chapter0", pageStarts: [0]),
            1: makeChapterLayout(text: "abcdefghijklmnopqrstuvwxyz", pageStarts: [0, 10, 20]),
        ]
        let position = CoreTextReadingPosition(spineIndex: 1, charOffset: 12)

        let page = CoreTextReadingPositionMapper.pageIndex(
            for: position,
            layouts: layouts,
            spinePageOffsets: [0, 5]
        )

        #expect(page == 6)
    }

    @Test func coreTextReadingPositionChapterEndResolvesToLastPage() {
        let layouts: [Int: CoreTextPaginator.ChapterLayout] = [
            0: makeChapterLayout(text: "chapter0", pageStarts: [0]),
            1: makeChapterLayout(text: "abcdefghijklmnopqrstuvwxyz", pageStarts: [0, 10, 20]),
        ]
        let position = CoreTextReadingPosition(spineIndex: 1, charOffset: .max)

        let page = CoreTextReadingPositionMapper.pageIndex(
            for: position,
            layouts: layouts,
            spinePageOffsets: [0, 5]
        )

        #expect(page == 7)
    }

    @Test func htmlBuilderConvertsBasicParagraph() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = "<p>Hello <strong>world</strong></p>"
        let result = await builder.build(html: html, config: config).attributedString
        #expect(result.string.contains("Hello"))
        #expect(result.string.contains("world"))
    }

    @Test func htmlBuilderInsertsPlaceholderForImg() async {
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in UIImage(systemName: "photo") }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = "<p>Before</p><img src='cover.jpg'><p>After</p>"
        let result = await builder.build(html: html, config: config).attributedString
        #expect(result.string.contains("\u{FFFC}"))
        var hasDelegate = false
        result.enumerateAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            in: NSRange(location: 0, length: result.length),
            options: []
        ) { value, _, _ in
            if value != nil { hasDelegate = true }
        }
        #expect(hasDelegate)
    }

    @Test func coreTextPaginatorPreservesImageHitTargetMetadata() async throws {
        let builder = HTMLAttributedStringBuilder()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.2,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 260
        )
        let html = "<p><a href='https://example.com/full'><img src='../images/00005.jpeg' alt='cover art'></a></p>"
        let result = await builder.build(html: html, config: config).attributedString
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result,
            renderSize: CGSize(width: 320, height: 480),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )

        let attachment = try #require(imageAttachments(in: layout, pageIndex: 0).first)
        #expect(attachment.sourceHref == "../images/00005.jpeg")
        #expect(attachment.alt == "cover art")
        #expect(attachment.linkHref == "https://example.com/full")
        #expect(attachment.originalSize == CGSize(width: 80, height: 40))
    }

    @Test func coreTextRenderPageCompositesTransparentImagesOverReaderBackground() async throws {
        let imageFormat = UIGraphicsImageRendererFormat()
        imageFormat.opaque = false
        let transparentImage = UIGraphicsImageRenderer(
            size: CGSize(width: 40, height: 20),
            format: imageFormat
        ).image { ctx in
            UIColor.systemRed.setFill()
            ctx.cgContext.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }

        let readerBackground = UIColor(red: 0.20, green: 0.40, blue: 0.60, alpha: 1)
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in transparentImage }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.2,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: readerBackground,
            renderWidth: 260
        )
        let result = await builder.build(html: "<p><img src='transparent.png' alt='transparent'></p>", config: config).attributedString
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result,
            renderSize: CGSize(width: 320, height: 220),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )
        let attachment = try #require(imageAttachments(in: layout, pageIndex: 0).first)

        let rendered = UIGraphicsImageRenderer(size: layout.renderSize).image { context in
            CoreTextPageView.renderPage(
                layout: layout,
                pageIndex: 0,
                in: context.cgContext,
                bounds: CGRect(origin: .zero, size: layout.renderSize)
            )
        }

        guard let cgImage = rendered.cgImage,
              let providerData = cgImage.dataProvider?.data
        else {
            Issue.record("Unable to inspect rendered image data")
            return
        }

        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow
        let x = max(0, min(cgImage.width - 1, Int(attachment.rect.minX + attachment.rect.width * 0.25)))
        let y = max(0, min(cgImage.height - 1, Int(attachment.rect.midY)))
        let idx = y * bytesPerRow + x * bytesPerPixel
        guard idx + 2 < data.count else {
            Issue.record("Transparent sample is outside rendered image data")
            return
        }

        let b = Int(data[idx])
        let g = Int(data[idx + 1])
        let r = Int(data[idx + 2])
        #expect(abs(r - 51) <= 6)
        #expect(abs(g - 102) <= 6)
        #expect(abs(b - 153) <= 6)
    }

    @Test func coreTextPaginatorMakesBlockRenderableImagesTappable() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 36)).image { ctx in
            UIColor.systemGreen.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 120, height: 36))
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in image }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.2,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 260
        )
        let html = """
        <html><head><style>
        .chapter-title { background-color: #ffffff; width: 240px; height: 42px; text-align: center; }
        .chapter-title img { width: 120px; height: 36px; }
        </style></head><body>
        <div class="chapter-title"><a href="https://example.com/full"><img src="../images/chapter.png" alt="Chapter 1"></a></div>
        </body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result,
            renderSize: CGSize(width: 320, height: 220),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )

        let renderable = try #require(layout.blockRenderables[0]?.first(where: { $0.imageAttachment != nil }))
        let attachment = try #require(renderable.imageAttachment)
        #expect(attachment.sourceHref == "../images/chapter.png")
        #expect(attachment.alt == "Chapter 1")
        #expect(attachment.linkHref == "https://example.com/full")
        #expect(attachment.rect.width > 0)
        #expect(attachment.rect.height > 0)
    }

    @Test func coreTextThemeUpdateRecolorsImageBlockBackgroundMatchingReaderBackground() async throws {
        let imageFormat = UIGraphicsImageRendererFormat()
        imageFormat.opaque = false
        let transparentImage = UIGraphicsImageRenderer(
            size: CGSize(width: 80, height: 24),
            format: imageFormat
        ).image { ctx in
            UIColor.systemRed.setFill()
            ctx.cgContext.fill(CGRect(x: 40, y: 0, width: 40, height: 24))
        }
        let oldBackground = UIColor.white
        let newBackground = UIColor(red: 0.83, green: 0.77, blue: 0.66, alpha: 1)
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in transparentImage }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.2,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: oldBackground,
            renderWidth: 260
        )
        let html = """
        <html><head><style>
        .chapter-title { background-color: #ffffff; width: 240px; height: 32px; text-align: left; }
        .chapter-title img { width: 80px; height: 24px; }
        </style></head><body>
        <div class="chapter-title"><img src="transparent-title.png" alt="transparent"></div>
        </body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result,
            renderSize: CGSize(width: 320, height: 220),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )

        let updated = layout.withUpdatedColors(textColor: .black, backgroundColor: newBackground)
        let renderable = try #require(updated.blockRenderables[0]?.first(where: { $0.imageAttachment != nil }))
        let fillColor = try #require(renderable.style.backgroundFillColor)
        #expect(colorsApproximatelyEqual(fillColor, newBackground))
    }

    @Test func epubBlockBoxReservesPaddingAndMarginsInReflowLayout() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 260
        )
        let html = """
        <html><head><style>
        body { font-family: serif; line-height: 1.6; margin: 1em; }
        h1 { text-align: center; }
        p { text-indent: 2em; margin: 0 0 0.8em 0; }
        .box { border: 1px solid #444; padding: 0.8em; margin: 1em 0; background: #f6f6f6; }
        .note { font-size: 0.85em; }
        </style></head><body>
        <h1>EPUB 2：NCX + XHTML Reflow</h1>
        <p>這個檔案是 EPUB 2.0 範例。它使用 OPF 2.0、NCX 目錄，以及 XHTML 1.1 內容文件。</p>
        <p>你在 Apple Books 和自己的 reader 裡看到的應該都是一般可重排文字：改字體大小後，行數與分頁會跟著變。</p>
        <div class="box">觀察點：這本書沒有 EPUB 3 的 nav document、fixed-layout metadata、HTML5 semantic section、ruby/MathML/SVG 這些測試點。</div>
        <p class="note">這個範例故意很普通，用來當 baseline。</p>
        </body></html>
        """
        let attributedString = await builder.build(html: html, config: config).attributedString
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 720),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )

        let box = try #require(layout.blockRenderables[0]?.first(where: { $0.style.backgroundFillColor != nil }))
        let fillColor = try #require(box.style.backgroundFillColor)
        #expect(colorsApproximatelyEqual(fillColor, UIColor(red: 246.0 / 255.0, green: 246.0 / 255.0, blue: 246.0 / 255.0, alpha: 1)))
        #expect(box.attributedText == nil)
        #expect(!hasBackgroundColorInCSSBlockRanges(attributedString))
        #expect(box.style.borderTopWidth > 0)
        #expect(box.style.borderBottomWidth > 0)
        #expect(box.style.borderLeftWidth > 0)
        #expect(box.style.borderRightWidth > 0)
        #expect(abs(box.style.paddingTop - 14.4) < 0.5)
        #expect(abs(box.style.paddingBottom - 14.4) < 0.5)
        #expect(abs(box.style.paddingLeft - 14.4) < 0.5)
        #expect(abs(box.style.paddingRight - 14.4) < 0.5)
        #expect(box.rect.height >= 28.8 + box.style.paddingTop + box.style.paddingBottom - 0.5)

        let headingLine = try #require(firstLineRect(containing: "Reflow", in: layout, pageIndex: 0))
        let boxTextLine = try #require(firstLineRect(containing: "觀察點", in: layout, pageIndex: 0))
        #expect(abs(headingLine.midX - layout.renderSize.width / 2) < 2)
        #expect(box.rect.minY >= headingLine.maxY)
        #expect(boxTextLine.minY >= box.rect.minY - 0.5)
        #expect(boxTextLine.maxY <= box.rect.maxY + 0.5)

        if let noteLine = firstLineRect(containing: "baseline", in: layout, pageIndex: 0) {
            #expect(noteLine.minY >= box.rect.maxY - 0.5)
        }
    }

    @Test func epubCalloutBlockHeightIncludesWrappedLines() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 260
        )
        let html = """
        <html><head><style>
        body { font-family: -apple-system, serif; line-height: 1.65; margin: 1em; }
        section { margin-bottom: 1.2em; }
        h1 { text-align: center; }
        ruby { ruby-position: over; }
        .callout { border: 2px solid #333; padding: 0.8em; border-radius: 0.4em; background: #f7f7f7; }
        svg { display: block; margin: 1em auto; width: 240px; height: 120px; }
        </style></head><body>
        <section>
        <h1>EPUB 3：Nav + HTML5 + Ruby + SVG</h1>
        <p>這個檔案是 EPUB 3.0 範例。它使用 <code>nav.xhtml</code> 當目錄，而不是 EPUB 2 的 NCX。</p>
        <p>下面這個字使用 ruby：<ruby>漢<rt>ㄏㄢˋ</rt></ruby>。如果 reader 支援 EPUB 3 / HTML5 ruby，注音或註解應該會顯示在文字旁邊或上方。</p>
        <div class="callout">觀察點：Apple Books 通常會處理 nav、ruby、HTML5 結構。你的 app 若只把 HTML 當普通文字或只走 EPUB 2 思路，這裡容易看出差異。</div>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 120" role="img" aria-label="Inline SVG demo">
          <rect x="10" y="10" width="220" height="100" rx="12" fill="#e9eefc" stroke="#333" stroke-width="3"/>
          <circle cx="70" cy="60" r="28" fill="#ffd966" stroke="#333" stroke-width="2"/>
          <text x="120" y="68" font-size="20" text-anchor="middle">SVG</text>
        </svg>
        </section>
        </body></html>
        """
        let attributedString = await builder.build(html: html, config: config).attributedString
        #expect(attributedString.string.contains("EPUB 2 思路，這裡容易看出差異"))

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 720),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )

        let finalLineMatch = try #require(firstLineRect(containing: "異", in: layout))
        let callout = try #require(layout.blockRenderables[finalLineMatch.pageIndex]?.first(where: { renderable in
            renderable.style.backgroundFillColor != nil
        }))
        #expect(callout.attributedText == nil)
        #expect(!hasBackgroundColorInCSSBlockRanges(attributedString))
        let finalLine = finalLineMatch.rect
        #expect(finalLine.maxY <= callout.rect.maxY + 0.5)
    }

    @Test func renderableNodeCalloutBlockHeightIncludesWrappedLines() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 260
        )
        let html = """
        <html><head><style>
        body { font-family: -apple-system, serif; line-height: 1.65; margin: 1em; }
        section { margin-bottom: 1.2em; }
        h1 { text-align: center; }
        ruby { ruby-position: over; }
        .callout { border: 2px solid #333; padding: 0.8em; border-radius: 0.4em; background: #f7f7f7; }
        svg { display: block; margin: 1em auto; width: 240px; height: 120px; }
        </style></head><body>
        <section>
        <h1>EPUB 3：Nav + HTML5 + Ruby + SVG</h1>
        <p>這個檔案是 EPUB 3.0 範例。它使用 <code>nav.xhtml</code> 當目錄，而不是 EPUB 2 的 NCX。</p>
        <p>下面這個字使用 ruby：<ruby>漢<rt>ㄏㄢˋ</rt></ruby>。如果 reader 支援 EPUB 3 / HTML5 ruby，注音或註解應該會顯示在文字旁邊或上方。</p>
        <div class="callout">觀察點：Apple Books 通常會處理 nav、ruby、HTML5 結構。你的 app 若只把 HTML 當普通文字或只走 EPUB 2 思路，這裡容易看出差異。</div>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 120" role="img" aria-label="Inline SVG demo">
          <rect x="10" y="10" width="220" height="100" rx="12" fill="#e9eefc" stroke="#333" stroke-width="3"/>
          <circle cx="70" cy="60" r="28" fill="#ffd966" stroke="#333" stroke-width="2"/>
          <text x="120" y="68" font-size="20" text-anchor="middle">SVG</text>
        </svg>
        </section>
        </body></html>
        """
        let ast = try #require(await builder.buildStyledAST(html: html, config: config))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: .black,
                renderWidth: 260
            )
        )
        let attributedString = await renderer.render(nodes)
        #expect(attributedString.string.contains("EPUB 2 思路，這裡容易看出差異"))

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 720),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )

        let finalLineMatch = try #require(firstLineRect(containing: "異", in: layout))
        let callout = try #require(layout.blockRenderables[finalLineMatch.pageIndex]?.first(where: { renderable in
            renderable.style.backgroundFillColor != nil
        }))
        #expect(callout.attributedText == nil)
        let finalLine = finalLineMatch.rect
        #expect(finalLine.maxY <= callout.rect.maxY + 0.5)
    }

    @Test func coreTextPaginatorCacheHandlesConcurrentPreloadRequests() async {
        let paginator = CoreTextPaginator()
        let first = NSAttributedString(string: "第一章\n這是普通 EPUB reflow 測試內容。")
        let second = NSAttributedString(string: "第二章\n這是另一個同時預載的章節。")

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let attr = index.isMultiple(of: 2) ? first : second
                    _ = await paginator.paginate(
                        spineIndex: index % 2,
                        attrStr: attr,
                        renderSize: CGSize(width: 320, height: 480),
                        fontSize: 18,
                        lineSpacing: 4,
                        paragraphSpacing: 4,
                        contentInsets: UIEdgeInsets(top: 20, left: 24, bottom: 20, right: 24),
                        writingMode: .horizontal
                    )
                }
            }
        }
    }

    @Test func htmlBuilderMapsFontFamilyAlias() async {
        let builder = HTMLAttributedStringBuilder()
        builder.resolvedFontFamily = { name in
            name == "kai" ? "Courier" : nil
        }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><head><style>.kai { font-family: kai; font-weight: bold; }</style></head>
        <body><p class='kai'>你好</p></body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(font?.fontName.localizedCaseInsensitiveContains("courier") == true)
    }

    @Test func htmlBuilderPreservesPostScriptFontNameWhenWeightApplied() async {
        let builder = HTMLAttributedStringBuilder()
        builder.resolvedFontFamily = { name in
            name == "kai" ? "TimesNewRomanPSMT" : nil
        }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><head><style>.kai { font-family: kai; font-weight: bold; }</style></head>
        <body><p class='kai'>你好</p></body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(font?.fontName.localizedCaseInsensitiveContains("timesnewroman") == true)
    }

    @Test func htmlBuilderPreservesNestedBoldInsideBlock() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = "<p>Hello <strong>world</strong></p>"
        let result = await builder.build(html: html, config: config).attributedString

        let regularFont = result.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let boldIndex = (result.string as NSString).range(of: "world").location
        let boldFont = result.attribute(.font, at: boldIndex, effectiveRange: nil) as? UIFont

        #expect(regularFont?.fontName != boldFont?.fontName)
    }

    @Test func htmlBuilderAppliesCSSColor() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><head><style>.title { color: #254c8b; }</style></head>
        <body><p class='title'>標題</p></body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString
        let color = result.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(color != UIColor.black)
    }

    @Test func htmlBuilderStylesInternalLinks() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let result = await builder.build(
            html: "<p>Go to <a href='#chapter-2'>Chapter 2</a></p>",
            config: config
        ).attributedString
        let linkRange = (result.string as NSString).range(of: "Chapter 2")
        #expect(linkRange.location != NSNotFound)

        let link = result.attribute(
            HTMLAttributedStringBuilder.internalLinkAttribute,
            at: linkRange.location,
            effectiveRange: nil
        ) as? String
        let foreground = result.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? UIColor
        let preservedForeground = result.attribute(
            HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute,
            at: linkRange.location,
            effectiveRange: nil
        ) as? UIColor
        let underline = result.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int

        #expect(link == "#chapter-2")
        #expect(foreground.map { colorsApproximatelyEqual($0, .systemBlue) } == true)
        #expect(preservedForeground.map { colorsApproximatelyEqual($0, .systemBlue) } == true)
        #expect(underline == NSUnderlineStyle.single.rawValue)
    }

    @Test func renderableNodeRendererStylesInternalLinks() async throws {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let ast = try #require(await builder.buildStyledAST(
            html: "<p>Go to <a href='#chapter-2'>Chapter 2</a></p>",
            config: config
        ))
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: .black,
                renderWidth: 375
            )
        )
        let result = await renderer.render(nodes)
        let linkRange = (result.string as NSString).range(of: "Chapter 2")
        #expect(linkRange.location != NSNotFound)

        let link = result.attribute(
            HTMLAttributedStringBuilder.internalLinkAttribute,
            at: linkRange.location,
            effectiveRange: nil
        ) as? String
        let foreground = result.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? UIColor
        let preservedForeground = result.attribute(
            HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute,
            at: linkRange.location,
            effectiveRange: nil
        ) as? UIColor
        let underline = result.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int

        #expect(link == "#chapter-2")
        #expect(foreground.map { colorsApproximatelyEqual($0, .systemBlue) } == true)
        #expect(preservedForeground.map { colorsApproximatelyEqual($0, .systemBlue) } == true)
        #expect(underline == NSUnderlineStyle.single.rawValue)
    }

    @Test func htmlBuilderDelegatesFontSelectionWithWeightAndItalic() async {
        let builder = HTMLAttributedStringBuilder()
        var capturedFamilies: [String] = []
        var capturedWeight = 0
        var capturedItalic = false
        var capturedSize: CGFloat = 0
        builder.resolvedFont = { families, weight, italic, size in
            capturedFamilies = families
            capturedWeight = weight
            capturedItalic = italic
            capturedSize = size
            return UIFont(name: "Courier", size: size)
        }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><head><style>.emph { font-family: kai; font-weight: 700; font-style: italic; }</style></head>
        <body><p class='emph'>測試</p></body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString
        let font = result.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(capturedFamilies == ["kai"])
        #expect(capturedWeight == 700)
        #expect(capturedItalic == true)
        #expect(capturedSize == 18)
        #expect(font?.fontName.localizedCaseInsensitiveContains("courier") == true)
    }

    @Test func htmlBuilderKeepsInlineSpeakerAndDialogueInSameParagraph() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = "<p class='normaltext'><b class='calibre3'>青年：</b>那麼，我就重新向您發問了。</p>"
        let result = await builder.build(html: html, config: config).attributedString

        #expect(result.string.contains("青年：那麼，我就重新向您發問了。"))
        #expect(!result.string.contains("青年：\n"))
        #expect(!result.string.contains("青年：\u{2028}"))
    }

    @Test func htmlBuilderUsesLineSeparatorForBrWithoutCreatingParagraphBreak() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = "<p>青年：<br/>那麼，我就重新向您發問了。</p>"
        let result = await builder.build(html: html, config: config).attributedString

        #expect(result.string.contains("\u{2028}"))
        #expect(!result.string.contains("\n\n"))
    }

    @Test func htmlBuilderSkipsWhitespaceOnlyTextNodesBetweenParagraphs() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><body><div>
            <p>第一段</p>
            <p>第二段</p>
        </div></body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString
        let hasWhitespaceOnlyGap = result.string.range(
            of: #"(?:\n|\u{2028})[ \t]{2,}(?:\n|\u{2028})"#,
            options: .regularExpression
        ) != nil
        #expect(hasWhitespaceOnlyGap == false)
    }

    @Test func htmlBuilderPreservesDecorativeBlockWithWhitespaceContent() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 320
        )
        let html = """
        <html><head><style>
        .shangkuang { display: block; width: 200px; border-top: #254c8b double 3px; margin: 0.5em 0; }
        </style></head><body>
        <div class='shangkuang'>      </div>
        <p>正文</p>
        </body></html>
        """

        let result = await builder.build(html: html, config: config).attributedString
        var foundDecorativeBlock = false
        result.enumerateAttribute(
            HTMLAttributedStringBuilder.blockRenderStyleAttribute,
            in: NSRange(location: 0, length: result.length),
            options: []
        ) { value, _, stop in
            guard let style = value as? HTMLAttributedStringBuilder.BlockRenderStyle else { return }
            if style.borderTopWidth > 0 {
                foundDecorativeBlock = true
                stop.pointee = true
            }
        }
        #expect(foundDecorativeBlock)
    }

    @Test func htmlBuilderTreatsBlockBrAsParagraphBreak() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><head><style>.calibre1 { display: block; }</style></head>
        <body><p class='banquan'>书名：测试<br class='calibre1'/>作者：某某</p></body></html>
        """
        let result = await builder.build(html: html, config: config).attributedString

        #expect(result.string.contains("书名：测试\n作者：某某"))
        #expect(!result.string.contains("\u{2028}"))

        let authorIndex = (result.string as NSString).range(of: "作者：某某").location
        let titleParagraph = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let authorParagraph = result.attribute(.paragraphStyle, at: authorIndex, effectiveRange: nil) as? NSParagraphStyle
        #expect(titleParagraph?.firstLineHeadIndent == 36)
        #expect(authorParagraph?.firstLineHeadIndent == 0)
    }

    @Test func htmlBuilderDoesNotTreatInlineBlockImageAsParagraphBoundary() async {
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in UIImage(systemName: "diamond.fill") }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><head><style>
        .title2 { color: #3767b4; display: block; font-size: 1.29167em; font-weight: bold; text-indent: 0; }
        .dian { display: inline-block; padding: 0 5px; }
        .normaltext { display: block; text-indent: 2em; }
        </style></head><body>
        <h2 class='title2'><img class='dian' src='diamond.jpeg'/>不为人知的心理学“第三巨头”</h2>
        <p class='normaltext'><b>青年：</b>刚才您提到“另一种哲学”。</p>
        </body></html>
        """

        let result = await builder.build(html: html, config: config).attributedString
        let string = result.string

        #expect(string.contains("不为人知的心理学“第三巨头”\n青年：刚才您提到“另一种哲学”。"))
        #expect(!string.contains("不为人知的心理学“第三巨头”青年："))
    }

    @Test func htmlBuilderLoadsPageBackgroundAndCentersFixedWidthTitleBlock() async {
        let builder = HTMLAttributedStringBuilder()
        let background = UIGraphicsImageRenderer(size: CGSize(width: 422, height: 751)).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 422, height: 751))
        }
        builder.imageLoader = { src in
            src == "images/00008.jpeg" ? background : nil
        }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 320
        )
        let html = """
        <html><head><style>
        .part { background-image: url(images/00008.jpeg); }
        .title1 { color: #fff; display: block; width: 280px; margin: 200px auto 0; text-indent: 0; }
        </style></head><body class='part'>
        <h1 class='title1'>第一夜\u{2028}我们的不幸是谁的错？</h1>
        </body></html>
        """

        let result = await builder.build(html: html, config: config)
        #expect(result.pageBackgroundImage != nil)
        #expect(result.pageBackgroundImageSource == "images/00008.jpeg")
        let titleIndex = (result.attributedString.string as NSString).range(of: "第一夜").location
        let paragraph = result.attributedString.attribute(.paragraphStyle, at: titleIndex, effectiveRange: nil) as? NSParagraphStyle
        let fillColor = result.attributedString.attribute(
            HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
            at: titleIndex,
            effectiveRange: nil
        ) as? UIColor
        #expect(paragraph?.headIndent == 20)
        #expect(paragraph?.tailIndent == -20)
        #expect(fillColor == nil)
    }

    @Test func htmlBuilderEmitsGenericBlockRenderStyleForBackgroundAndBorders() async {
        let builder = HTMLAttributedStringBuilder()
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 320
        )
        let html = """
        <html><head><style>
        .title1 {
            display: block;
            width: 280px;
            margin: 200px auto 0;
            text-indent: 0;
            background: rgba(55,103,180,0.2);
            border-top: currentColor double 3px;
        }
        </style></head><body><h1 class='title1'>第一夜</h1></body></html>
        """

        let result = await builder.build(html: html, config: config).attributedString
        let titleIndex = (result.string as NSString).range(of: "第一夜").location
        let renderStyle = result.attribute(
            HTMLAttributedStringBuilder.blockRenderStyleAttribute,
            at: titleIndex,
            effectiveRange: nil
        ) as? HTMLAttributedStringBuilder.BlockRenderStyle

        #expect(renderStyle != nil)
        #expect(renderStyle?.backgroundFillColor != nil)
        #expect((renderStyle?.borderTopWidth ?? 0) > 0)
        #expect(abs((renderStyle?.width ?? 0) - 280) < 0.1)
        #expect(renderStyle?.isHorizontallyCentered == true)
    }

    @Test func htmlBuilderAppliesInlineImageCssGeometry() async {
        let builder = HTMLAttributedStringBuilder()
        let diamond = UIGraphicsImageRenderer(size: CGSize(width: 36, height: 35)).image { ctx in
            UIColor.systemBlue.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 36, height: 35))
        }
        builder.imageLoader = { _ in diamond }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 320
        )
        let html = """
        <html><head><style>
        .dian { display: inline-block; height: 14px; padding: 0 5px; }
        </style></head><body><h2><img class='dian' src='diamond.jpeg'/>不为人知的心理学“第三巨头”</h2></body></html>
        """

        let result = await builder.build(html: html, config: config)
        let attributedString = result.attributedString
        var captured: ImageRunInfo?
        attributedString.enumerateAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, _, stop in
            guard let value else { return }
            let delegate = value as! CTRunDelegate
            let ptr = CTRunDelegateGetRefCon(delegate)
            captured = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
            stop.pointee = true
        }

        #expect(captured != nil)
        #expect(abs((captured?.drawHeight ?? 0) - 14) < 0.1)
        #expect(abs((captured?.paddingLeft ?? 0) - 5) < 0.1)
        #expect(abs((captured?.paddingRight ?? 0) - 5) < 0.1)
        #expect(abs((captured?.width ?? 0) - 24.4) < 1.0)
        #expect((captured?.ascent ?? 0) > 14)
        #expect((captured?.descent ?? 0) >= 0)
    }

    @Test func htmlBuilderUsesCssWidthForBlockDecorativeImageWhenHeightIsAuto() async {
        let builder = HTMLAttributedStringBuilder()
        let banner = UIGraphicsImageRenderer(size: CGSize(width: 452, height: 74)).image { ctx in
            UIColor(red: 0.72, green: 0.82, blue: 0.98, alpha: 1).setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 452, height: 74))
        }
        builder.imageLoader = { _ in banner }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 320
        )
        let html = """
        <html><head><style>
        .dibian { display: block; text-align: right; margin-top: 0.5em; margin-bottom: 0.5em; }
        .calibre5 { width: 220px; height: auto; opacity: 0.2; }
        </style></head><body>
        <div class='dibian'><img class='calibre5' src='banner.jpeg'/></div>
        </body></html>
        """

        let result = await builder.build(html: html, config: config).attributedString
        var captured: ImageRunInfo?
        result.enumerateAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            in: NSRange(location: 0, length: result.length),
            options: []
        ) { value, _, stop in
            guard let value else { return }
            let delegate = value as! CTRunDelegate
            let ptr = CTRunDelegateGetRefCon(delegate)
            captured = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
            stop.pointee = true
        }

        if let captured {
            #expect(abs(captured.drawWidth - 220) < 1.0)
            #expect(abs(captured.drawHeight - (220.0 * 74.0 / 452.0)) < 1.0)
        }
    }

    @Test func epubNodeRendererReservesHeightForFourthWingChapterLogo() async throws {
        let builder = HTMLAttributedStringBuilder()
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 135, height: 134)).image { ctx in
            UIColor.systemPurple.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 135, height: 134))
        }
        builder.imageLoader = { _ in logo }
        let htmlConfig = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.2,
            lineSpacing: 4,
            paragraphSpacing: 4,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 260
        )
        let html = """
        <html><head><style>
        .class_sxf { display: block; text-align: center; text-indent: 0; }
        .class_sxe { width: 24.03%; height: auto; }
        .class_sxh { display: block; font-size: 1.5em; font-weight: bold; line-height: 1.2; text-align: center; text-indent: 0; margin: 0 0 0.704225em; }
        </style></head><body>
        <div class="class_sxf">
            <img src="logo.png" alt="publisher logo" class="class_sxe"/>
        </div>
        <p class="class_sxh">CHAPTER <br/>ONE</p>
        </body></html>
        """

        let ast = try #require(await builder.buildStyledAST(html: html, config: htmlConfig))
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: ReaderRenderSettings(
                    theme: "test",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.2,
                    lineSpacing: 4,
                    paragraphSpacing: 4,
                    letterSpacing: 0,
                    marginH: 30,
                    marginV: 20,
                    footerHeight: 0,
                    contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
                    writingMode: .horizontal
                ),
                textColor: .black,
                renderWidth: 260,
                imageLoader: { _ in logo }
            )
        )
        let attributedString = await renderer.render(HTMLStyledASTRenderableNodeConverter.convert(body: ast))

        var captured: ImageRunInfo?
        attributedString.enumerateAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, _, stop in
            guard let value else { return }
            let delegate = value as! CTRunDelegate
            let ptr = CTRunDelegateGetRefCon(delegate)
            captured = Unmanaged<ImageRunInfo>.fromOpaque(ptr).takeUnretainedValue()
            stop.pointee = true
        }
        let info = try #require(captured)
        #expect(info.displayMode == .block)
        #expect(abs(info.drawWidth - (260 * 0.2403)) < 1.0)
        #expect(abs(info.drawHeight - ((260 * 0.2403) * 134 / 135)) < 1.0)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: attributedString,
            renderSize: CGSize(width: 320, height: 360),
            fontSize: 18,
            lineSpacing: 4,
            paragraphSpacing: 4,
            letterSpacing: 0,
            contentInsets: UIEdgeInsets(top: 20, left: 30, bottom: 20, right: 30),
            writingMode: .horizontal
        )
        let renderable = try #require(layout.blockRenderables[0]?.first(where: { $0.imageAttachment != nil }))
        let attachment = try #require(renderable.imageAttachment)
        #expect(attachment.sourceHref == "logo.png")
        #expect(attachment.alt == "publisher logo")
        #expect(renderable.rect.height >= attachment.rect.height)
        #expect(abs(attachment.rect.midX - 160) < 1.0)

        let chapterLineRect = try #require(firstLineRect(
            containing: "CHAPTER",
            in: layout,
            pageIndex: 0
        ))
        #expect(!attachment.rect.intersects(chapterLineRect))
        #expect(chapterLineRect.minY >= attachment.rect.maxY - 0.5)
    }

    private func firstLineRect(
        containing needle: String,
        in layout: CoreTextPaginator.ChapterLayout,
        pageIndex: Int
    ) -> CGRect? {
        guard pageIndex < layout.pageRanges.count else { return nil }
        let range = layout.pageRanges[pageIndex]
        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: layout.renderSize,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let frame = CTFramesetterCreateFrame(
            layout.framesetter,
            range,
            CGPath(rect: contentPathRect, transform: nil),
            nil
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.location >= 0,
                  lineRange.location + lineRange.length <= layout.attributedString.length
            else { continue }
            let text = (layout.attributedString.string as NSString).substring(
                with: NSRange(location: lineRange.location, length: lineRange.length)
            )
            guard text.contains(needle) else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let origin = origins[index]
            return CGRect(
                x: contentPathRect.minX + origin.x,
                y: layout.renderSize.height - (contentPathRect.minY + origin.y + ascent),
                width: width,
                height: ascent + descent
            )
        }
        return nil
    }

    private func firstLineRect(
        containing needle: String,
        in layout: CoreTextPaginator.ChapterLayout
    ) -> (pageIndex: Int, rect: CGRect)? {
        for pageIndex in layout.pageRanges.indices {
            if let rect = firstLineRect(containing: needle, in: layout, pageIndex: pageIndex) {
                return (pageIndex, rect)
            }
        }
        return nil
    }

    private func hasBackgroundColorInCSSBlockRanges(_ attributedString: NSAttributedString) -> Bool {
        guard attributedString.length > 0 else { return false }
        var found = false
        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, stop in
            guard value != nil else { return }
            attributedString.enumerateAttribute(.backgroundColor, in: range) { background, _, innerStop in
                if background != nil {
                    found = true
                    innerStop.pointee = true
                    stop.pointee = true
                }
            }
        }
        return found
    }

    @Test func htmlBuilderDetectsSingleImagePage() async {
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { _ in UIImage(systemName: "book") }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 375
        )
        let html = """
        <html><body><div><svg><image xlink:href='cover.jpeg' width='100' height='160' /></svg></div></body></html>
        """
        let result = await builder.build(html: html, config: config)
        #expect(result.imagePage?.source == "cover.jpeg")
    }

    @Test func paginatorPageRangesTotalLengthEqualsAttrStrLength() async {
        let text = String(repeating: "一二三四五六七八九十", count: 200)
        let attrStr = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let paginator = CoreTextPaginator()
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attrStr,
            renderSize: CGSize(width: 375, height: 600),
            fontSize: 18
        )
        let total = layout.pageRanges.reduce(0) { $0 + $1.length }
        #expect(total == attrStr.length)
        #expect(!layout.pageRanges.isEmpty)
    }

    @Test func paginatorBinarySearchFindsCorrectPage() async {
        let text = String(repeating: "Hello world ", count: 300)
        let attrStr = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let paginator = CoreTextPaginator()
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attrStr,
            renderSize: CGSize(width: 375, height: 600),
            fontSize: 18
        )
        guard layout.pageRanges.count > 1 else { return }
        let secondPageStart = Int(layout.pageRanges[1].location)
        let foundPage = layout.pageIndex(for: secondPageStart)
        #expect(foundPage == 1)
    }

    @Test func charOffsetStoreProgressMigrationApproximatesPosition() async {
        let attrStr = NSAttributedString(
            string: String(repeating: "a", count: 1000),
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let progression = 0.5
        let charOffset = Int(progression * Double(attrStr.length))
        #expect(charOffset == 500)
        let paginator = CoreTextPaginator()
        let layout = await paginator.paginate(
            spineIndex: 0,
            attrStr: attrStr,
            renderSize: CGSize(width: 375, height: 600),
            fontSize: 18
        )
        let page = layout.pageIndex(for: charOffset)
        #expect(page >= 0)
        #expect(page < layout.pageRanges.count)
    }

    @Test func charOffsetSurvivesFontSizeChange() async {
        // 同一段文字，字號從 18 改成 24，charOffset 指向同一個字符段落
        let text = String(repeating: "測試文字內容，這是一段較長的段落用於驗證重排後位置還原。", count: 50)
        let attrStr18 = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        let attrStr24 = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 24)]
        )
        let paginator = CoreTextPaginator()
        let size = CGSize(width: 375, height: 600)

        let layout18 = await paginator.paginate(spineIndex: 0, attrStr: attrStr18, renderSize: size, fontSize: 18)
        let layout24 = await paginator.paginate(spineIndex: 1, attrStr: attrStr24, renderSize: size, fontSize: 24)

        // 字號 18 時讀到第 2 頁
        guard layout18.pageRanges.count > 2 else { return }
        let charOffset = Int(layout18.pageRanges[2].location)

        // 字號改成 24 後，charOffset 應仍落在 layout24 的某頁範圍內
        let page24 = layout24.pageIndex(for: charOffset)
        let range24 = layout24.pageRanges[page24]
        #expect(range24.location <= charOffset)
        #expect(charOffset < range24.location + range24.length)
    }

    @Test func readerRestoreResolverReturnsNilWhenPositionUnavailable() {
        let resolvedPage = ReaderProgressRestoreResolver.resolvePage(
            chapterIndex: 0,
            charOffset: 14_000_000
        ) { _ in
            nil
        }

        #expect(resolvedPage == nil)
    }

    @Test func readerRestoreResolverAcceptsResolvedFirstPage() {
        let resolvedPage = ReaderProgressRestoreResolver.resolvePage(
            chapterIndex: 0,
            charOffset: 120
        ) { _ in
            0
        }

        #expect(resolvedPage == 0)
    }

    @Test func readerProgressSyncPolicySkipsStartupOverwriteWhenEngineNotReady() {
        let shouldPersist = ReaderProgressSyncPolicy.shouldPersistOnPageChanged(
            isCoreTextReady: true,
            totalPages: 0,
            isRestoringPosition: false
        )
        #expect(shouldPersist == false)
    }

    @Test func readerProgressSyncPolicyAllowsPersistAfterReady() {
        let shouldPersist = ReaderProgressSyncPolicy.shouldPersistOnPageChanged(
            isCoreTextReady: true,
            totalPages: 4206,
            isRestoringPosition: false
        )
        #expect(shouldPersist == true)
    }

    @Test func coreTextEngineDoesNotRestoreFromLegacyCharOffsetStore() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextSingleRestoreSource-\(UUID().uuidString)")
        let bookId = "single-source-\(UUID().uuidString)"
        let offsetStore = CharOffsetStore(directoryURL: dir, debounceInterval: 0)
        offsetStore.save(CharOffsetRecord(
            bookId: bookId,
            spineIndex: 3,
            charOffset: 5,
            timestamp: Date()
        ))
        offsetStore.flushSync()

        let settings = ReaderRenderSettings(
            theme: "light",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero
        )
        let engine = await MainActor.run {
            CoreTextPageEngine(
                attributedBuilder: ProgressFallbackBuilder(chapterCount: 5),
                renderSettings: settings,
                offsetStore: offsetStore
            )
        }

        await engine.start(renderSize: CGSize(width: 320, height: 480), bookId: bookId)

        let currentPage = await MainActor.run { engine.currentPage }
        #expect(currentPage == 0)
    }

    @Test func coreTextProgressFallsBackToChapterRatioBeforeByteScan() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextProgressFallback-\(UUID().uuidString)")
        let offsetStore = CharOffsetStore(directoryURL: dir)
        let settings = ReaderRenderSettings(
            theme: "light",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero
        )

        let progress = await MainActor.run { () -> Double in
            let engine = CoreTextPageEngine(
                attributedBuilder: ProgressFallbackBuilder(chapterCount: 100),
                renderSettings: settings,
                offsetStore: offsetStore
            )
            return engine.totalProgress(forSpine: 50, charOffset: 0)
        }

        #expect(abs(progress - 0.5) < 0.0001)
    }

    @Test func coreTextProgressFallbackClampsOutOfRangeSpine() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextProgressFallback-\(UUID().uuidString)")
        let offsetStore = CharOffsetStore(directoryURL: dir)
        let settings = ReaderRenderSettings(
            theme: "light",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 24,
            marginV: 16,
            footerHeight: 24,
            contentInsets: .zero
        )

        let progress = await MainActor.run { () -> Double in
            let engine = CoreTextPageEngine(
                attributedBuilder: ProgressFallbackBuilder(chapterCount: 100),
                renderSettings: settings,
                offsetStore: offsetStore
            )
            return engine.totalProgress(forSpine: 999, charOffset: 0)
        }

        #expect(abs(progress - 0.99) < 0.0001)
    }

    @Test func addBookImportGuardRejectsStaleSessionResult() {
        let active = UUID()
        let stale = UUID()
        let accepted = AddBookImportGuard.shouldApplyResult(
            activeSessionID: active,
            resultSessionID: stale,
            isCancelled: false
        )
        #expect(accepted == false)
    }

    @Test func addBookImportGuardRejectsCancelledResult() {
        let session = UUID()
        let accepted = AddBookImportGuard.shouldApplyResult(
            activeSessionID: session,
            resultSessionID: session,
            isCancelled: true
        )
        #expect(accepted == false)
    }

    @Test func addBookImportGuardAcceptsMatchingActiveResult() {
        let session = UUID()
        let accepted = AddBookImportGuard.shouldApplyResult(
            activeSessionID: session,
            resultSessionID: session,
            isCancelled: false
        )
        #expect(accepted == true)
    }

    @Test @MainActor func refreshOnlineBookMetadataRepairsLegacyShelfEntry() async throws {
        guard hasBookSourceFixture else { return }
        let source = try loadSource(named: "速读谷")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer {
            BookSourceStore.shared.sources = previousSources
        }

        let books = try await BookSourceFetcher.shared.search(query: "斗罗大陆", in: source)
        let exactMatch = books.first(where: { $0.name == "斗罗大陆" })
        let partialMatch = books.first(where: { $0.name.contains("斗罗大陆") })
        let book = try #require(exactMatch ?? partialMatch)

        let store = BookStore()
        let stale = store.addOnlineBook(
            name: book.name,
            author: book.author,
            sourceId: source.id,
            bookInfoURL: book.bookUrl,
            tocURL: nil,
            runtimeVariables: nil,
            chapters: []
        )
        defer {
            store.delete(bookId: stale.id)
        }

        let refreshed = try await store.refreshOnlineBookMetadata(
            bookId: stale.id,
            forceInfoRefresh: true
        )
        #expect(!(refreshed.tocURL ?? "").isEmpty)
        #expect((refreshed.onlineChapters?.isEmpty ?? true) == false)

        let current = try #require(store.books.first(where: { $0.id == stale.id }))
        let package = try await ChapterFetchManager.shared.fetchChapter(
            book: current,
            chapterIndex: 0,
            priority: .jump,
            store: store
        )
        #expect(!package.content.isEmpty)
        BookSourceFetcher.shared.clearAllChapterCache(bookId: stale.id)
    }

    @Test func refreshOnlineBookMetadataPersistsFirstTOCPageBeforeFullFetchCompletes() async throws {
        let source = BookSource(bookSourceUrl: "https://example.com", bookSourceName: "測試書源")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer {
            BookSourceStore.shared.sources = previousSources
        }

        let store = BookStore()
        let stale = store.addOnlineBook(
            name: "測試書",
            author: "作者",
            sourceId: source.id,
            bookInfoURL: "https://example.com/book",
            tocURL: "https://example.com/toc",
            runtimeVariables: nil,
            chapters: []
        )
        defer {
            store.delete(bookId: stale.id)
        }

        let firstPage = [
            OnlineChapterRef(index: 0, title: "第 1 章", url: "https://example.com/c1"),
            OnlineChapterRef(index: 1, title: "第 2 章", url: "https://example.com/c2"),
        ]
        let fullTOC = firstPage + [
            OnlineChapterRef(index: 2, title: "第 3 章", url: "https://example.com/c3")
        ]
        let fetcher = ProgressiveTOCFetcher(
            source: source,
            firstPageChapters: firstPage,
            finalPackage: TOCPackage(
                sourceId: source.id,
                sourceName: source.bookSourceName,
                tocURL: "https://example.com/toc",
                runtimeVariables: ["token": "final"],
                chapters: fullTOC,
                rawHTMLFilename: nil,
                savedAt: Date()
            )
        )

        let refreshTask = Task {
            try await store.refreshOnlineBookMetadata(
                bookId: stale.id,
                forceInfoRefresh: false,
                bookSourceFetcher: fetcher
            )
        }

        var intermediate: ReadingBook?
        for _ in 0..<100 {
            if let current = store.books.first(where: { $0.id == stale.id }),
               current.onlineChapters?.count == firstPage.count {
                intermediate = current
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let repairedEarly = try #require(intermediate)
        #expect(repairedEarly.onlineChapters?.map { $0.title } == firstPage.map { $0.title })

        await fetcher.gate.release()
        let refreshed = try await refreshTask.value
        #expect(refreshed.onlineChapters?.map { $0.title } == fullTOC.map { $0.title })
        #expect(refreshed.runtimeVariables?["token"] == "final")
    }

    @Test func fetchWebContentProgressivelyPublishesFirstPageBeforeNextPageCompletes() async throws {
        StubPaginatedURLProtocol.reset()
        let firstURL = "https://example.com/chapter-1"
        let secondURL = "https://example.com/chapter-1?page=2"
        let firstText = String(repeating: "第一頁內容", count: 80)
        let secondText = String(repeating: "第二頁內容", count: 80)

        StubPaginatedURLProtocol.htmlByURL = [
            firstURL: """
            <html><body><article><p>\(firstText)</p><a href="\(secondURL)">下一頁</a></article></body></html>
            """,
            secondURL: """
            <html><body><article><p>\(secondText)</p></article></body></html>
            """
        ]
        StubPaginatedURLProtocol.blockingURL = secondURL

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubPaginatedURLProtocol.self]
        let session = URLSession(configuration: config)
        let webFetcher = WebFetcher(session: session)
        let fetcher = BookSourceFetcher(webFetcher: webFetcher)

        var firstPageContent: String?
        let task = Task {
            try await fetcher.fetchWebContent(
                url: firstURL,
                referer: nil,
                onFirstPageReady: { partial in
                    firstPageContent = partial
                }
            )
        }

        for _ in 0..<100 {
            if firstPageContent?.contains("第一頁內容") == true {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(firstPageContent?.contains("第一頁內容") == true)
        #expect(firstPageContent?.contains("第二頁內容") != true)

        StubPaginatedURLProtocol.blockSemaphore.signal()
        let finalContent = try await task.value
        #expect(finalContent.contains("第一頁內容"))
        #expect(finalContent.contains("第二頁內容"))
    }

    @Test func onlineInitialChapterResolverPrefersRestoreTargetAndProgress() {
        let explicit = OnlineInitialChapterResolver.preferredInitialChapter(
            chapterCount: 3000,
            savedPositionSnapshot: 0,
            restoreTargetChapter: 100
        )
        #expect(explicit == 100)

        let fromProgress = OnlineInitialChapterResolver.preferredInitialChapter(
            chapterCount: 3000,
            savedPositionSnapshot: 100.0 / 2999.0,
            restoreTargetChapter: nil
        )
        #expect(fromProgress == 100)

        let clamped = OnlineInitialChapterResolver.preferredInitialChapter(
            chapterCount: 10,
            savedPositionSnapshot: 2.0,
            restoreTargetChapter: 99
        )
        #expect(clamped == 9)
    }

    @Test func coreTextEngineLoadsActualPartPageBackgroundImage() async throws {
        guard let sourceURL = testEPUBURL else { return }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPageBackgroundTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)

        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        #expect(layout.pageBackgroundImage != nil)
        #expect(layout.attributedString.string.contains("第一夜"))
        #expect(layout.attributedString.string.contains("我们的不幸是谁的错？"))

        let titleRange = (layout.attributedString.string as NSString).range(of: "第一夜")
        #expect(titleRange.location != NSNotFound)
        if titleRange.location != NSNotFound {
            let textColor = layout.attributedString.attribute(.foregroundColor, at: titleRange.location, effectiveRange: nil) as? UIColor
            let renderStyle = layout.attributedString.attribute(
                HTMLAttributedStringBuilder.blockRenderStyleAttribute,
                at: titleRange.location,
                effectiveRange: nil
            ) as? HTMLAttributedStringBuilder.BlockRenderStyle
            #expect(textColor != nil)
            #expect(renderStyle?.backgroundFillColor != nil)
        }
        let firstRenderable = try #require(layout.blockRenderables[0]?.first)
        #expect(firstRenderable.rect.minY < layout.renderSize.height * 0.7)
        #expect(firstRenderable.rect.maxY < layout.renderSize.height * 0.9)
        #expect(abs(firstRenderable.rect.width - 280) < 2.0)
    }

    @Test func coreTextEngineRendersActualPart0010BodyText() async throws {
        guard let sourceURL = testEPUBURL else { return }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0010Test-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0010.html"))
        await engine.preloadChapter(at: chapterIndex)

        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        #expect(layout.attributedString.string.contains("一进入书房"))
        #expect((layout.blockAttachments[0]?.isEmpty ?? true) == false)

        let blockAttachment = try #require(layout.blockAttachments[0]?.first)
        #expect(abs(blockAttachment.rect.width - 220) < 2.0)
        #expect(abs(blockAttachment.rect.height - (220.0 * 74.0 / 452.0)) < 2.0)
        let firstRenderable = try #require(layout.blockRenderables[0]?.first)
        #expect(abs(firstRenderable.rect.width - 200) < 3.0)

        let pageSize = layout.renderSize
        let image = await MainActor.run { () -> UIImage in
            let view = CoreTextPageView(frame: CGRect(origin: .zero, size: pageSize))
            view.configure(layout: layout, pageIndex: 0)
            return UIGraphicsImageRenderer(size: pageSize).image { context in
                CoreTextPageView.renderPage(
                    layout: layout,
                    pageIndex: 0,
                    in: context.cgContext,
                    bounds: CGRect(origin: .zero, size: pageSize)
                )
            }
        }
        if let data = image.pngData() {
            try? data.write(to: URL(fileURLWithPath: "/tmp/part0009-render.png"))
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect rendered image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow
        var foundDarkPixel = false
        for y in stride(from: 180, to: 520, by: 8) {
            for x in stride(from: 40, to: 320, by: 8) {
                let idx = y * bytesPerRow + x * bytesPerPixel
                guard idx + 2 < data.count else { continue }
                let b = Int(data[idx])
                let g = Int(data[idx + 1])
                let r = Int(data[idx + 2])
                if r < 220 || g < 220 || b < 220 {
                    foundDarkPixel = true
                    break
                }
            }
            if foundDarkPixel { break }
        }
        #expect(foundDarkPixel)
    }


    @Test func coreTextEngineRendersActualPart0009TitleCardAboveLowerHalf() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009RenderTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let debugRects = layout.blockRenderables[0]?.map(\.rect) ?? []
        print("[TEST part0009] renderSize=", layout.renderSize)
        print("[TEST part0009] pageKinds=", layout.pageKinds)
        print("[TEST part0009] pageBackgroundImage nil? ", layout.pageBackgroundImage == nil)
        print("[TEST part0009] blockRenderables=", debugRects)
        if let first = layout.blockRenderables[0]?.first {
            print("[TEST part0009] block style width=", first.style.width as Any, "height=", first.style.height as Any, "bg=", first.style.backgroundFillColor as Any, "spacingBefore=", first.style.paragraphSpacingBefore)
        }
        print("[TEST part0009] text=", layout.attributedString.string)
        #expect((layout.blockRenderables[0]?.count ?? 0) == 1, "part0009 block renderables = \(debugRects)")
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)
        let renderableText = try #require(titleRenderable.attributedText)
        #expect(renderableText.string.contains("第一夜"))
        #expect(renderableText.string.contains("我们的不幸是谁的错"))
        let firstForeground = renderableText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(firstForeground != nil)

        let pageSize = layout.renderSize
        let image = await MainActor.run { () -> UIImage in
            let rendered = UIGraphicsImageRenderer(size: pageSize).image { context in
                CoreTextPageView.renderPage(
                    layout: layout,
                    pageIndex: 0,
                    in: context.cgContext,
                    bounds: CGRect(origin: .zero, size: pageSize)
                )
            }
            if let data = rendered.pngData() {
                try? data.write(to: URL(fileURLWithPath: "/tmp/part0009-render.png"))
            }
            return rendered
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect rendered image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        var foundBlueInMiddleBand = false
        for y in stride(from: 240, to: 520, by: 8) {
            for x in stride(from: 60, to: 330, by: 8) {
                guard let (r,g,b) = sample(x, y) else { continue }
                if b > r + 15 && b > g + 15 && !(r > 240 && g > 240 && b > 240) {
                    foundBlueInMiddleBand = true
                    break
                }
            }
            if foundBlueInMiddleBand { break }
        }

        var foundBlueOnlyAtBottom = false
        for y in stride(from: 620, to: 820, by: 8) {
            for x in stride(from: 60, to: 330, by: 8) {
                guard let (r,g,b) = sample(x, y) else { continue }
                if b > r + 15 && b > g + 15 && !(r > 240 && g > 240 && b > 240) {
                    foundBlueOnlyAtBottom = true
                    break
                }
            }
            if foundBlueOnlyAtBottom { break }
        }

        var bluePixelCount = 0
        var sampledPixelCount = 0
        for y in stride(from: 60, to: 760, by: 12) {
            for x in stride(from: 24, to: 366, by: 12) {
                guard let (r, g, b) = sample(x, y) else { continue }
                sampledPixelCount += 1
                if b > r + 15 && b > g + 15 && !(r > 240 && g > 240 && b > 240) {
                    bluePixelCount += 1
                }
            }
        }

        #expect(foundBlueInMiddleBand)
        #expect(!foundBlueOnlyAtBottom)
        #expect(bluePixelCount > max(20, sampledPixelCount / 20))
    }

    @Test func coreTextEngineRendersActualPart0009VisibleTitleTextInsideCard() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009VisibleTitleTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)

        let pageSize = layout.renderSize
        let image = await MainActor.run { () -> UIImage in
            UIGraphicsImageRenderer(size: pageSize).image { context in
                CoreTextPageView.renderPage(
                    layout: layout,
                    pageIndex: 0,
                    in: context.cgContext,
                    bounds: CGRect(origin: .zero, size: pageSize)
                )
            }
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect rendered image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        let minX = max(0, Int(titleRenderable.rect.minX) + 24)
        let maxX = min(cgImage.width - 1, Int(titleRenderable.rect.maxX) - 24)
        let minY = max(0, Int(titleRenderable.rect.minY) + 20)
        let maxY = min(cgImage.height - 1, Int(titleRenderable.rect.maxY) - 20)

        let sampleCenterX = min(max(minX + 8, (minX + maxX) / 2), maxX)
        let sampleCenterY = min(max(minY + 8, (minY + maxY) / 2), maxY)
        let baseFill = try #require(sample(sampleCenterX, sampleCenterY))

        var foundContrastPixel = false
        var foundBrightGlyphPixel = false
        for y in stride(from: minY, through: maxY, by: 3) {
            for x in stride(from: minX, through: maxX, by: 3) {
                guard let (r, g, b) = sample(x, y) else { continue }
                let distance =
                    abs(r - baseFill.0) +
                    abs(g - baseFill.1) +
                    abs(b - baseFill.2)
                if distance > 45 {
                    foundContrastPixel = true
                }
                if r > 235 && g > 235 && b > 235 {
                    foundBrightGlyphPixel = true
                }
            }
            if foundContrastPixel && foundBrightGlyphPixel { break }
        }

        #expect(
            foundContrastPixel,
            "Expected visible title glyph pixels inside the title card rect. fill=\(baseFill) rect=\(titleRenderable.rect)"
        )
        #expect(
            foundBrightGlyphPixel,
            "Expected bright title glyph pixels inside the title card rect. fill=\(baseFill) rect=\(titleRenderable.rect)"
        )
    }

    @Test func coreTextEnginePromotesActualPart0009TitleCardTextIntoBlockRenderable() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009BlockTextTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)
        let blockText = try #require(titleRenderable.attributedText)

        #expect(blockText.string.contains("第一夜"))
        #expect(blockText.string.contains("我们的不幸是谁的错？"))
    }

    @Test func coreTextEngineNormalizesActualPart0009BlockTextParagraphGeometry() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009BlockTextGeometryTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)
        let blockText = try #require(titleRenderable.attributedText)

        let paragraphStyle = try #require(
            blockText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )

        #expect(paragraphStyle.paragraphSpacingBefore == 0)
        #expect(paragraphStyle.paragraphSpacing == 0)
        #expect(paragraphStyle.alignment == .center)
        #expect(paragraphStyle.firstLineHeadIndent == 0)
        #expect(paragraphStyle.headIndent == 0)
        #expect(paragraphStyle.tailIndent == 0)
    }

    @Test func debugActualPart0009BlockTextMetrics() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009DebugMetrics-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)
        let text = try #require(titleRenderable.attributedText)
        let measured = text.boundingRect(
            with: CGSize(width: max(1, titleRenderable.rect.width - titleRenderable.style.paddingLeft - titleRenderable.style.paddingRight),
                         height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let attrs = text.attributes(at: 0, effectiveRange: nil)
        print("[TEST part0009 debug] rect=", titleRenderable.rect)
        print("[TEST part0009 debug] text=", text.string)
        print("[TEST part0009 debug] measured=", measured)
        print("[TEST part0009 debug] attrs=", attrs)
        #expect(!text.string.isEmpty)
    }

    @Test func coreTextEnginePlacesActualPart0009TitleLinesInsideTitleCard() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009LinePlacementTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)
        let range = layout.pageRanges[0]
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: bounds.size,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let path = CGPath(rect: contentPathRect, transform: nil)
        let frame = CTFramesetterCreateFrame(layout.framesetter, range, path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        let titleText = "第一夜\n我们的不幸是谁的错？"
        let titleRange = (layout.attributedString.string as NSString).range(of: titleText)
        #expect(titleRange.location != NSNotFound)

        var titleLineRects: [CGRect] = []
        for (index, line) in lines.enumerated() {
            let stringRange = CTLineGetStringRange(line)
            let lineRange = NSRange(location: stringRange.location, length: stringRange.length)
            guard NSIntersectionRange(lineRange, titleRange).length > 0 else { continue }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let origin = origins[index]
            let rect = CGRect(
                x: contentPathRect.minX + origin.x,
                y: bounds.height - (contentPathRect.minY + origin.y + ascent),
                width: width,
                height: ascent + descent
            )
            titleLineRects.append(rect)
        }

        #expect(!titleLineRects.isEmpty)
        let union = titleLineRects.reduce(into: CGRect.null) { partial, rect in
            partial = partial.isNull ? rect : partial.union(rect)
        }

        let overlap = union.intersection(titleRenderable.rect)
        print("[TEST part0009 lines] titleRect=", titleRenderable.rect, "lineUnion=", union, "overlap=", overlap)
        #expect(!overlap.isNull && overlap.height > 20, "Expected title text lines to overlap title card. rect=\(titleRenderable.rect) lines=\(union)")
    }

    @Test func coreTextEngineSnapshotViewControllerRendersActualPart0009Background() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009SnapshotTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let globalPage = await MainActor.run { engine.pageIndex(forSpine: chapterIndex, charOffset: 0) }
        let snapshotVC = try #require(await MainActor.run { engine.snapshotViewController(at: globalPage) as? SnapshotPageViewController })

        let image = await MainActor.run { () -> UIImage in
            snapshotVC.view.frame = CGRect(origin: .zero, size: layout.renderSize)
            snapshotVC.loadViewIfNeeded()
            let rendered = UIGraphicsImageRenderer(size: layout.renderSize).image { context in
                snapshotVC.view.drawHierarchy(in: snapshotVC.view.bounds, afterScreenUpdates: true)
            }
            if let data = rendered.pngData() {
                try? data.write(to: URL(fileURLWithPath: "/tmp/part0009-snapshot.png"))
            }
            return rendered
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect snapshot image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        var foundBlue = false
        for y in stride(from: 90, to: 240, by: 8) {
            for x in stride(from: 40, to: 350, by: 8) {
                guard let (r, g, b) = sample(x, y) else { continue }
                if b > r + 20 && b > g + 20 && !(r > 240 && g > 240 && b > 240) {
                    foundBlue = true
                    break
                }
            }
            if foundBlue { break }
        }

        #expect(foundBlue)
    }

    @Test func coreTextEngineSnapshotViewControllerRendersActualPart0009VisibleTitleTextInsideCard() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009SnapshotVisibleTitle-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)
        let globalPage = await MainActor.run { engine.pageIndex(forSpine: chapterIndex, charOffset: 0) }
        let snapshotVC = try #require(await MainActor.run { engine.snapshotViewController(at: globalPage) as? SnapshotPageViewController })

        let image = await MainActor.run { () -> UIImage in
            snapshotVC.view.frame = CGRect(origin: .zero, size: layout.renderSize)
            snapshotVC.loadViewIfNeeded()
            return UIGraphicsImageRenderer(size: layout.renderSize).image { _ in
                snapshotVC.view.drawHierarchy(in: snapshotVC.view.bounds, afterScreenUpdates: true)
            }
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect snapshot image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        let minX = max(0, Int(titleRenderable.rect.minX) + 24)
        let maxX = min(cgImage.width - 1, Int(titleRenderable.rect.maxX) - 24)
        let minY = max(0, Int(titleRenderable.rect.minY) + 20)
        let maxY = min(cgImage.height - 1, Int(titleRenderable.rect.maxY) - 20)

        let sampleCenterX = min(max(minX + 8, (minX + maxX) / 2), maxX)
        let sampleCenterY = min(max(minY + 8, (minY + maxY) / 2), maxY)
        let baseFill = try #require(sample(sampleCenterX, sampleCenterY))

        var foundContrastPixel = false
        var foundBrightGlyphPixel = false
        for y in stride(from: minY, through: maxY, by: 3) {
            for x in stride(from: minX, through: maxX, by: 3) {
                guard let (r, g, b) = sample(x, y) else { continue }
                let distance =
                    abs(r - baseFill.0) +
                    abs(g - baseFill.1) +
                    abs(b - baseFill.2)
                if distance > 45 {
                    foundContrastPixel = true
                }
                if r > 235 && g > 235 && b > 235 {
                    foundBrightGlyphPixel = true
                }
            }
            if foundContrastPixel && foundBrightGlyphPixel { break }
        }

        #expect(foundContrastPixel, "Expected visible snapshot title glyph pixels inside the title card rect. fill=\(baseFill) rect=\(titleRenderable.rect)")
        #expect(foundBrightGlyphPixel, "Expected bright snapshot title glyph pixels inside the title card rect. fill=\(baseFill) rect=\(titleRenderable.rect)")
    }

    @Test @MainActor
    func snapshotPageViewControllerFillsBoundsInsteadOfLetterboxing() throws {
        let expected = (Int(0.15 * 255.0), Int(0.35 * 255.0), Int(0.75 * 255.0))
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { ctx in
            UIColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let snapshotVC = SnapshotPageViewController(
            image: sourceImage,
            globalPage: 0,
            backgroundColor: .white
        )
        snapshotVC.view.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        snapshotVC.loadViewIfNeeded()

        let rendered = UIGraphicsImageRenderer(size: snapshotVC.view.bounds.size).image { _ in
            snapshotVC.view.drawHierarchy(in: snapshotVC.view.bounds, afterScreenUpdates: true)
        }

        guard let cgImage = rendered.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect snapshot image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        let topLeft = try #require(sample(10, 10))
        let bottomRight = try #require(sample(cgImage.width - 10, cgImage.height - 10))

        func isNonBackground(_ rgb: (Int, Int, Int)) -> Bool {
            !(rgb.0 > 240 && rgb.1 > 240 && rgb.2 > 240)
        }

        func isNear(_ lhs: (Int, Int, Int), _ rhs: (Int, Int, Int)) -> Bool {
            abs(lhs.0 - rhs.0) < 20 &&
            abs(lhs.1 - rhs.1) < 20 &&
            abs(lhs.2 - rhs.2) < 20
        }

        #expect(isNonBackground(topLeft), "Expected snapshot image to fill top-left. pixel=\(topLeft), expected=\(expected)")
        #expect(isNonBackground(bottomRight), "Expected snapshot image to fill bottom-right. pixel=\(bottomRight), expected=\(expected)")
        #expect(isNear(topLeft, bottomRight), "Expected filled corners to come from the same image. topLeft=\(topLeft), bottomRight=\(bottomRight)")
    }

    @Test func coreTextPageViewLiveRenderShowsActualPart0009TitleGlyphsInsideCard() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009LiveRender-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)

        let image = await MainActor.run { () -> UIImage in
            let view = CoreTextPageView(frame: CGRect(origin: .zero, size: layout.renderSize))
            view.configure(layout: layout, pageIndex: 0)
            view.layoutIfNeeded()
            return UIGraphicsImageRenderer(size: layout.renderSize).image { context in
                view.layer.render(in: context.cgContext)
            }
        }

        let debugURL = URL(fileURLWithPath: "/Users/zhangruilin/Desktop/yuedu app/.debug-part0009-live-render.png")
        try image.pngData()?.write(to: debugURL)
        print("[TEST part0009 live render] image=", debugURL.path)
        print("[TEST part0009 live render] rect=", titleRenderable.rect)
        print("[TEST part0009 live render] text=", titleRenderable.attributedText?.string ?? "<nil>")

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect live rendered image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        let minX = max(0, Int(titleRenderable.rect.minX) + 24)
        let maxX = min(cgImage.width - 1, Int(titleRenderable.rect.maxX) - 24)
        let minY = max(0, Int(titleRenderable.rect.minY) + 20)
        let maxY = min(cgImage.height - 1, Int(titleRenderable.rect.maxY) - 20)

        var foundBrightGlyphPixel = false
        for y in stride(from: minY, through: maxY, by: 3) {
            for x in stride(from: minX, through: maxX, by: 3) {
                guard let (r, g, b) = sample(x, y) else { continue }
                if r > 235 && g > 235 && b > 235 {
                    foundBrightGlyphPixel = true
                    break
                }
            }
            if foundBrightGlyphPixel { break }
        }

        #expect(foundBrightGlyphPixel, "Expected bright live title glyph pixels inside the title card rect. rect=\(titleRenderable.rect)")
    }

    @Test func coreTextPageViewLiveRenderShowsActualPart0009BlueBackgroundNearTop() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009LiveBackground-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })

        let image = await MainActor.run { () -> UIImage in
            let view = CoreTextPageView(frame: CGRect(origin: .zero, size: layout.renderSize))
            view.configure(layout: layout, pageIndex: 0)
            view.layoutIfNeeded()
            return UIGraphicsImageRenderer(size: layout.renderSize).image { context in
                view.layer.render(in: context.cgContext)
            }
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect live render image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        var foundBlue = false
        for y in stride(from: 40, through: min(220, cgImage.height - 1), by: 8) {
            for x in stride(from: 40, through: min(cgImage.width - 40, cgImage.width - 1), by: 8) {
                guard let (r, g, b) = sample(x, y) else { continue }
                if b > g + 15 && g > r + 10 {
                    foundBlue = true
                    break
                }
            }
            if foundBlue { break }
        }

        #expect(foundBlue, "Expected visible blue background pixels near top of live rendered part0009 page")
    }

    @Test func coreTextEnginePlacesActualPart0010BottomDecorationBelowBodyText() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0010DecorationPlacement-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0010.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let decoration = try #require(layout.blockAttachments[0]?.first(where: { $0.rect.width > 150 }))

        let range = layout.pageRanges[0]
        let bounds = CGRect(origin: .zero, size: layout.renderSize)
        let contentPathRect = CoreTextPaginator.coreTextContentPathRect(
            renderSize: bounds.size,
            contentInsets: layout.contentInsets,
            fontSize: layout.fontSize,
            writingMode: layout.writingMode
        )
        let path = CGPath(rect: contentPathRect, transform: nil)
        let frame = CTFramesetterCreateFrame(layout.framesetter, range, path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)

        var union = CGRect.null
        for (index, line) in lines.enumerated() {
            let stringRange = CTLineGetStringRange(line)
            guard stringRange.length > 0 else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let origin = origins[index]
            let rect = CGRect(
                x: contentPathRect.minX + origin.x,
                y: bounds.height - (contentPathRect.minY + origin.y + ascent),
                width: width,
                height: ascent + descent
            )
            union = union.isNull ? rect : union.union(rect)
        }

        #expect(!union.isNull)
        #expect(
            decoration.rect.minY >= union.maxY + 8,
            "Expected part0010 bottom decoration below body text. decoration=\(decoration.rect) text=\(union)"
        )
    }

    @Test func coreTextPageViewDrawBlockRenderableTextDrawsVisibleGlyphs() async throws {
        let font = UIFont.systemFont(ofSize: 28, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        let text = NSAttributedString(
            string: "第一夜\u{2028}我们的不幸是谁的错？",
            attributes: [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
        )

        let pageSize = CGSize(width: 390, height: 844)
        let cardRect = CGRect(x: 55, y: 290, width: 280, height: 132)

        let image = await MainActor.run { () -> UIImage in
            UIGraphicsImageRenderer(size: pageSize).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pageSize))
                context.cgContext.setFillColor(UIColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 1).cgColor)
                context.cgContext.fill(cardRect)
                CoreTextPageView.drawBlockRenderableText(
                    text,
                    in: cardRect,
                    paddingTop: 0,
                    paddingLeft: 0,
                    paddingBottom: 0,
                    paddingRight: 0,
                    boundsHeight: pageSize.height,
                    context: context.cgContext
                )
            }
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect rendered image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        var foundBrightPixel = false
        for y in stride(from: Int(cardRect.minY) + 12, to: Int(cardRect.maxY) - 12, by: 3) {
            for x in stride(from: Int(cardRect.minX) + 12, to: Int(cardRect.maxX) - 12, by: 3) {
                guard let (r, g, b) = sample(x, y) else { continue }
                if r > 235 && g > 235 && b > 235 {
                    foundBrightPixel = true
                    break
                }
            }
            if foundBrightPixel { break }
        }

        #expect(foundBrightPixel, "Expected bright white glyphs inside the blue title card")
    }

    @Test func coreTextPageViewRenderPageKeepsPart0009TitleVisibleWhenBoundsDifferFromLayoutSize() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0009ScaledRender-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })
        let titleRenderable = try #require(layout.blockRenderables[0]?.first)

        let targetBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let image = await MainActor.run { () -> UIImage in
            UIGraphicsImageRenderer(size: targetBounds.size).image { context in
                CoreTextPageView.renderPage(
                    layout: layout,
                    pageIndex: 0,
                    in: context.cgContext,
                    bounds: targetBounds
                )
            }
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect scaled rendered image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let idx = y * bytesPerRow + x * bytesPerPixel
            guard idx + 2 < data.count else { return nil }
            return (Int(data[idx + 2]), Int(data[idx + 1]), Int(data[idx]))
        }

        let scaleX = targetBounds.width / layout.renderSize.width
        let scaleY = targetBounds.height / layout.renderSize.height
        let scaledRect = CGRect(
            x: titleRenderable.rect.minX * scaleX,
            y: titleRenderable.rect.minY * scaleY,
            width: titleRenderable.rect.width * scaleX,
            height: titleRenderable.rect.height * scaleY
        )

        let minX = max(0, Int(scaledRect.minX) + 24)
        let maxX = min(cgImage.width - 1, Int(scaledRect.maxX) - 24)
        let minY = max(0, Int(scaledRect.minY) + 20)
        let maxY = min(cgImage.height - 1, Int(scaledRect.maxY) - 20)

        var foundBrightGlyphPixel = false
        for y in stride(from: minY, through: maxY, by: 3) {
            for x in stride(from: minX, through: maxX, by: 3) {
                guard let (r, g, b) = sample(x, y) else { continue }
                if r > 235 && g > 235 && b > 235 {
                    foundBrightGlyphPixel = true
                    break
                }
            }
            if foundBrightGlyphPixel { break }
        }

        #expect(foundBrightGlyphPixel, "Expected bright title glyphs after scaling render from layout size \(layout.renderSize) to \(targetBounds.size)")
    }

    @Test func coreTextEngineRendersActualPart0010BottomDecoration() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0010RenderDecorTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0010.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })

        let image = await MainActor.run { () -> UIImage in
            let view = CoreTextPageView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            view.configure(layout: layout, pageIndex: 0)
            return UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { context in
                view.layer.render(in: context.cgContext)
            }
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect rendered image data")
            return
        }
        let data = providerData as Data
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow
        var foundBottomDecoration = false
        for y in stride(from: 560, to: 780, by: 8) {
            for x in stride(from: 140, to: 360, by: 8) {
                let idx = y * bytesPerRow + x * bytesPerPixel
                guard idx + 2 < data.count else { continue }
                let b = Int(data[idx])
                let g = Int(data[idx + 1])
                let r = Int(data[idx + 2])
                if !(r > 240 && g > 240 && b > 240) && b >= g && g >= r {
                    foundBottomDecoration = true
                    break
                }
            }
            if foundBottomDecoration { break }
        }
        #expect(foundBottomDecoration)
    }

    @Test func coreTextEngineDoesNotDuplicateActualPart0010BottomDecoration() async throws {
        guard let sourceURL = testEPUBURL else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreTextPart0010NoDupDecorTest-\(UUID().uuidString)")
        let engine = await MainActor.run {
            CoreTextPageEngine(
                session: session,
                renderSettings: ReaderRenderSettings(
                    theme: "light",
                    textColor: .black,
                    backgroundColor: .white,
                    fontSize: 18,
                    lineHeightMultiple: 1.4,
                    lineSpacing: 6,
                    paragraphSpacing: 8,
                    letterSpacing: 0,
                    marginH: 24,
                    marginV: 16,
                    footerHeight: 24,
                    contentInsets: .zero
                ),
                offsetStore: CharOffsetStore(directoryURL: storeDir)
            )
        }

        let chapterIndex = try #require(session.chapterIndex(for: "text/part0010.html"))
        await engine.preloadChapter(at: chapterIndex)
        let layout = try #require(await MainActor.run { engine.layouts[chapterIndex] })

        #expect((layout.blockRenderables[0]?.count ?? 0) > 0)
        #expect(layout.blockAttachments[0] == nil || layout.blockAttachments[0]?.isEmpty == true)
    }

    @Test func coreTextPageViewRendersBackgroundImagePixels() async {
        let builder = HTMLAttributedStringBuilder()
        let background = UIGraphicsImageRenderer(size: CGSize(width: 422, height: 751)).image { ctx in
            UIColor(red: 0.05, green: 0.35, blue: 0.75, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 422, height: 751))
        }
        builder.imageLoader = { src in
            src == "images/00008.jpeg" ? background : nil
        }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 6,
            paragraphSpacing: 8,
            firstLineIndent: 36,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 320
        )
        let html = """
        <html><head><style>
        .part { background-image: url(images/00008.jpeg); background-position: center center; background-repeat: no-repeat; background-size: contain; }
        .title1 { background: rgba(55, 103, 180, 0.2); color: #fff; display: block; width: 280px; margin: 200px auto 0; text-indent: 0; }
        </style></head><body class='part'>
        <h1 class='title1'>第一夜\u{2028}我们的不幸是谁的错？</h1>
        </body></html>
        """

        let buildResult = await builder.build(html: html, config: config)
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: buildResult.attributedString,
            imagePage: buildResult.imagePage,
            pageBackgroundImage: buildResult.pageBackgroundImage,
            anchorOffsets: buildResult.anchorOffsets,
            renderSize: CGSize(width: 390, height: 844),
            fontSize: config.fontSize,
            contentInsets: .init(top: 24, left: 32, bottom: 60, right: 32)
        )

        let image = await MainActor.run { () -> UIImage in
            let view = CoreTextPageView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            view.configure(layout: layout, pageIndex: 0)
            return UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { context in
                view.layer.render(in: context.cgContext)
            }
        }

        guard let cgImage = image.cgImage,
              let providerData = cgImage.dataProvider?.data else {
            Issue.record("Unable to inspect rendered image data")
            return
        }
        let data = providerData as Data
        let centerX = 195
        let centerY = 300
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.bytesPerRow
        let idx = centerY * bytesPerRow + centerX * bytesPerPixel
        guard idx + 2 < data.count else {
            Issue.record("Rendered image index out of range")
            return
        }
        let b = data[idx]
        let g = data[idx + 1]
        let r = data[idx + 2]
        #expect(!(r > 240 && g > 240 && b > 240))
    }

}
