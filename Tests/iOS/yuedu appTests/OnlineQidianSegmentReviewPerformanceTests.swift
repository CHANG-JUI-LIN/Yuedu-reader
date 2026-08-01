import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

private final class LiveChapterProvider: BookContentProvider {
    let payload: ChapterContentPayload

    init(_ payload: ChapterContentPayload) {
        self.payload = payload
    }

    var totalChapters: Int { 1 }
    func chapterTitle(at index: Int) -> String { payload.title }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == 0 else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payload
    }
}

@Suite("Live Qidian segment review performance", .serialized)
@MainActor
struct OnlineQidianSegmentReviewPerformanceTests {
    private static let sourcePath = "/Users/zhangruilin/Desktop/Test document/RULE/大灰狼起点.json"
    private static let reviewKeyEnvironment = "QIDIAN_REVIEW_KEY"

    @Test("measures chapter loading with segment reviews on and off")
    func measuresChapterLoading() async throws {
        guard let key = ProcessInfo.processInfo.environment[Self.reviewKeyEnvironment], !key.isEmpty else {
            Issue.record("Missing QIDIAN_REVIEW_KEY; live benchmark was not run")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.sourcePath))
        let source = try JSONDecoder().decode([BookSource].self, from: data).first
        guard let source else {
            Issue.record("No source in \(Self.sourcePath)")
            return
        }

        let loginManager = LoginManager.shared
        let previousLogin = loginManager.getLoginInfo(sourceUrl: source.bookSourceUrl)
        let runtimeStore = BookSourceRuntimeStateStore.shared
        let previousVariables = runtimeStore.sourceVariableJSON(for: source.bookSourceUrl)
        defer {
            if let previousLogin {
                loginManager.storeLoginInfo(sourceUrl: source.bookSourceUrl, info: previousLogin)
            } else {
                loginManager.clearLogin(sourceUrl: source.bookSourceUrl)
            }
            runtimeStore.setSourceVariableJSON(previousVariables, for: source.bookSourceUrl)
        }
        loginManager.storeLoginInfo(sourceUrl: source.bookSourceUrl, info: ["密钥": key])

        let fetcher = BookSourceFetcher.shared
        // This is the first book/chapter from the live 畅销榜 response at benchmark time.
        // Build the same data URL as the source's ruleToc so the measurement starts at the
        // chapter runtime (not at ranking/detail/TOC transport noise).
        let chapterPayload: [String: Any] = [
            "bookId": "1048522709", // 超人灭绝指南
            "id": "894511145", // 第001章 柯明庆
            "v": false
        ]
        let chapterData = try JSONSerialization.data(withJSONObject: chapterPayload)
        let chapterURL = "data:;base64,\(chapterData.base64EncodedString()),{\"type\":\"qtqd\"}"
        let ref = OnlineChapterRef(index: 0, title: "第001章 柯明庆", url: chapterURL)
        print("BENCH fixture book=超人灭绝指南 chapter=\(ref.title)")

        for (label, enabled) in [("reviews-off", false), ("reviews-on", true), ("reviews-on-warm", true)] {
            let variables = ["para": enabled]
            let variableData = try JSONSerialization.data(withJSONObject: variables)
            runtimeStore.setSourceVariableJSON(
                String(data: variableData, encoding: .utf8),
                for: source.bookSourceUrl
            )

            var benchmarkRef = ref
            benchmarkRef.runtimeVariables = ref.runtimeVariables
            let fetchStart = ProcessInfo.processInfo.systemUptime
            let package = try await fetcher.fetchChapterPackage(
                ref: benchmarkRef,
                bookId: UUID(),
                source: source
            )
            let fetchMs = (ProcessInfo.processInfo.systemUptime - fetchStart) * 1000

            let payload = ChapterContentPayload(
                index: 0,
                title: package.renderTitle,
                plainText: ReaderHTMLUtilities.displayText(fromHTMLFragment: package.content),
                body: .html(package.content),
                sourceHref: package.sourceURL
            )
            let builder = OnlineProviderAttributedStringBuilder(
                provider: LiveChapterProvider(payload),
                renderSize: CGSize(width: 390, height: 760)
            )
            let settings = ReaderRenderSettings(
                theme: "benchmark",
                textColor: .label,
                backgroundColor: .systemBackground,
                fontSize: 18,
                lineHeightMultiple: 1.4,
                lineSpacing: 0,
                paragraphSpacing: 8,
                letterSpacing: 0,
                marginH: 16,
                marginV: 16,
                footerHeight: 0,
                contentInsets: .zero,
                writingMode: .horizontal
            )
            let renderStart = ProcessInfo.processInfo.systemUptime
            let build = try await builder.buildChapter(
                at: 0,
                settings: settings,
                themeTextColor: .label,
                themeBackgroundColor: .systemBackground
            )
            let renderMs = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
            let paginationStart = ProcessInfo.processInfo.systemUptime
            let framesetter = CTFramesetterCreateWithAttributedString(build.attributedString)
            let framePath = CGPath(
                rect: CGRect(x: 0, y: 0, width: 390, height: 760),
                transform: nil
            )
            var cursor = 0
            var pageCount = 0
            while cursor < build.attributedString.length {
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: cursor, length: build.attributedString.length - cursor),
                    framePath,
                    nil
                )
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { break }
                cursor += visible.length
                pageCount += 1
            }
            let paginationMs = (ProcessInfo.processInfo.systemUptime - paginationStart) * 1000
            let svgCount = package.content.components(separatedBy: "data:image/svg+xml").count - 1
            let reviewCount = package.content.components(separatedBy: "showCmt(").count - 1
            let attachmentKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
            var attachmentCount = 0
            build.attributedString.enumerateAttribute(
                attachmentKey,
                in: NSRange(location: 0, length: build.attributedString.length)
            ) { _, _, _ in attachmentCount += 1 }
            print(
                "BENCH label=\(label) para=\(enabled) fetchMs=\(Int(fetchMs.rounded())) "
                    + "renderMs=\(Int(renderMs.rounded())) paginationMs=\(Int(paginationMs.rounded())) "
                    + "contentBytes=\(package.content.utf8.count) svg=\(svgCount) reviews=\(reviewCount) "
                    + "attributedLength=\(build.attributedString.length) attachments=\(attachmentCount) pages=\(pageCount)"
            )
        }
    }
}
