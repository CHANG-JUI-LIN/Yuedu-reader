import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite("CoreText scroll reader", .serialized)
struct CoreTextScrollTests {

    @Test("scroll axis exposes vertical and horizontal RTL modes")
    func scrollAxisCasesExist() {
        #expect(CoreTextScrollAxis.vertical.isHorizontalRTL == false)
        #expect(CoreTextScrollAxis.horizontalRTL.isHorizontalRTL == true)
    }

    @Test("reader theme UIKit colors are opaque for CoreText")
    func readerThemeUIKitColorsAreOpaque() {
        for theme in ReaderTheme.allCases {
            #expect(Self.alpha(of: theme.uiTextColor) == 1)
            #expect(Self.alpha(of: theme.uiBackgroundColor) == 1)
        }
    }

    @Test("reader theme uses WeChat reader day and night palette")
    func readerThemeUsesWeChatReaderPalette() {
        #expect(Self.bytes(of: ReaderTheme.white.uiBackgroundColor) == [244, 245, 247, 255])
        #expect(Self.bytes(of: ReaderTheme.white.uiBarColor) == [255, 255, 255, 255])
        #expect(Self.bytes(of: ReaderTheme.white.uiAccentColor) == [56, 151, 241, 255])
        #expect(Self.bytes(of: ReaderTheme.night.uiBackgroundColor) == [0, 0, 0, 255])
        #expect(Self.bytes(of: ReaderTheme.night.uiBarColor) == [26, 26, 26, 255])
        #expect(Self.bytes(of: ReaderTheme.night.uiAccentColor) == [56, 151, 241, 255])
    }

    @Test("collection scroll controller is available for vertical scroll")
    @MainActor
    func collectionScrollControllerInitializes() {
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: ["Hello"]),
            renderSettings: Self.renderSettings
        )

        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .vertical,
            horizontalInset: 12,
            verticalInset: 20,
            backgroundColor: .white
        )

        #expect(controller.scrollAxis == .vertical)
    }

    @Test("collection scroll controller supports horizontal RTL scroll")
    @MainActor
    func collectionScrollControllerInitializesHorizontalRTL() {
        let settings = Self.makeRenderSettings(writingMode: .verticalRTL)
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: ["直排測試內容"]),
            renderSettings: settings
        )

        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .horizontalRTL,
            horizontalInset: 12,
            verticalInset: 20,
            backgroundColor: .white
        )

        #expect(controller.scrollAxis == .horizontalRTL)
    }

    @Test("vertical RTL scroll cover fits viewport width instead of text extent")
    @MainActor
    func verticalRTLScrollCoverFitsViewportWidthInsteadOfTextExtent() async throws {
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { context in
            UIColor.systemRed.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        }
        let settings = Self.makeRenderSettings(writingMode: .verticalRTL)
        let engine = CoreTextScrollEngine(
            builder: ImagePageScrollTestBuilder(image: cover),
            renderSettings: settings
        )
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .horizontalRTL,
            horizontalInset: 24,
            verticalInset: 60,
            backgroundColor: .white
        )
        controller.bottomMargin = 32
        controller.setInitialPosition(chapter: 0, charOffset: 0)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        for _ in 0..<50 where !engine.isReady {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.view.layoutIfNeeded()

        let chunk = try #require(engine.chunks.first)
        let attachment = try #require(chunk.attachments.first)
        #expect(chunk.isImageOnly)
        #expect(abs(chunk.width - 342) < 1)
        #expect(abs(chunk.height - 752) < 1)
        #expect(attachment.rect.width <= chunk.width)
        #expect(attachment.rect.height <= chunk.height)
        window.isHidden = true
    }

    @Test("vertical RTL scroll keeps a visible chapter boundary gap")
    @MainActor
    func verticalRTLScrollKeepsVisibleChapterBoundaryGap() async throws {
        let settings = Self.makeRenderSettings(writingMode: .verticalRTL)
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: ["短章節。", "第二章節。"]),
            renderSettings: settings
        )
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .horizontalRTL,
            horizontalInset: 24,
            verticalInset: 60,
            backgroundColor: .white
        )
        controller.setInitialPosition(chapter: 0, charOffset: 0)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let collectionView = try #require(Self.firstCollectionView(in: controller.view))
        for _ in 0..<50 where engine.chapterRanges[1] == nil || collectionView.numberOfItems(inSection: 0) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }
        controller.view.layoutIfNeeded()

        try #require(engine.chunks.count > 1)
        let secondChunk = engine.chunks[1]
        let secondFrame = try #require(collectionView.layoutAttributesForItem(
            at: IndexPath(item: 1, section: 0)
        )?.frame)
        #expect(secondFrame.width - secondChunk.width >= 72)
        window.isHidden = true
    }

    @Test("horizontal RTL scroll starts at the mirrored leading edge")
    @MainActor
    func horizontalRTLInitialScrollStartsAtMirroredLeadingEdge() async throws {
        let settings = Self.makeRenderSettings(writingMode: .verticalRTL)
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: [Self.longVerticalChapter]),
            renderSettings: settings
        )
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .horizontalRTL,
            horizontalInset: 12,
            verticalInset: 20,
            backgroundColor: .white
        )
        controller.setInitialPosition(chapter: 0, charOffset: 0)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        for _ in 0..<50 where !engine.isReady {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.view.layoutIfNeeded()

        let collectionView = try #require(Self.firstCollectionView(in: controller.view))
        #expect(engine.isReady)
        #expect(collectionView.contentSize.width > collectionView.bounds.width)
        let minOffsetX = -collectionView.adjustedContentInset.left
        let maxOffsetX = max(minOffsetX, collectionView.contentSize.width - collectionView.bounds.width + collectionView.adjustedContentInset.right)
        #expect(collectionView.contentOffset.x >= minOffsetX - 0.5)
        #expect(collectionView.contentOffset.x <= maxOffsetX + 0.5)
        window.isHidden = true
    }

    @Test("collection scroll first load works before window attachment")
    @MainActor
    func collectionScrollFirstLoadBeforeWindowAttachmentDoesNotCrash() async throws {
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: [Self.longChapter]),
            renderSettings: Self.renderSettings
        )
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .vertical,
            horizontalInset: 12,
            verticalInset: 20,
            backgroundColor: .white
        )

        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.setInitialPosition(chapter: 0, charOffset: 0)
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        for _ in 0..<50 where !engine.isReady {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(engine.isReady)
        #expect(!engine.chunks.isEmpty)
    }

    @Test("TXT first switch to scroll mode loads through renderer without crashing")
    @MainActor
    func txtFirstSwitchToScrollModeLoadsThroughRenderer() async throws {
        let renderer = EPUBPageRenderer()
        renderer.loadTXT(
            text: Self.longTXT,
            title: "TXT first scroll switch",
            bookIdentifier: "CoreTextScrollTests-TXT-\(UUID().uuidString)",
            renderSize: Self.fixtureRenderSize,
            settings: Self.renderSettings
        )
        let engine = try #require(renderer.scrollEngine)
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .vertical,
            horizontalInset: 12,
            verticalInset: 20,
            backgroundColor: .white
        )

        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.setInitialPosition(chapter: 0, charOffset: 0)
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        for _ in 0..<50 where !engine.isReady {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(engine.isReady)
        #expect(!engine.chunks.isEmpty)
    }

    @Test("scroll engine warms chunks around a row without prewarming everything")
    @MainActor
    func scrollEngineWarmsNearbyChunks() async {
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: [Self.longChapter]),
            renderSettings: Self.renderSettings
        )
        await engine.start(initialChapter: 0, contentWidth: 220)
        let chunks = engine.chunks
        #expect(chunks.count >= 4)
        chunks.forEach { $0.evictFrame() }

        engine.warmChunks(around: 2, radius: 1)

        let materialized = chunks.enumerated().filter { $0.element.isMaterialized }.map(\.offset)
        #expect(materialized == [1, 2, 3])
    }

    @Test("scroll engine keeps old chunks visible while reslicing")
    @MainActor
    func scrollEngineKeepsOldChunksVisibleWhileReslicing() async throws {
        let engine = CoreTextScrollEngine(
            builder: DelayedScrollTestBuilder(chapters: [Self.longChapter], delayNanoseconds: 120_000_000),
            renderSettings: Self.renderSettings
        )
        await engine.start(initialChapter: 0, contentWidth: 220)
        let oldCount = engine.chunks.count
        try #require(engine.isReady)
        try #require(oldCount > 0)

        let resliceTask = Task { await engine.reslice(restoreAt: 0, contentWidth: 220) }
        await Task.yield()

        #expect(engine.isReady)
        #expect(engine.chunks.count == oldCount)

        await resliceTask.value
        #expect(engine.isReady)
        #expect(!engine.chunks.isEmpty)
    }

    @Test("chunk slicer keeps styled paragraph starts on chunk boundaries")
    func chunkSlicerStartsTrimmedChunksAtParagraphBoundaries() {
        let attr = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 28
        paragraphStyle.headIndent = 0
        paragraphStyle.minimumLineHeight = 22

        for index in 0..<24 {
            attr.append(NSAttributedString(
                string: "Heading \(index)\n",
                attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 24),
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: UIColor.black,
                ]
            ))
            attr.append(NSAttributedString(
                string: "This Project Hail Mary paragraph keeps enough English words to wrap across several lines in scroll mode without changing its paragraph style.\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 18),
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: UIColor.black,
                ]
            ))
        }

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 220,
            heightCap: 240
        )

        #expect(output.chunks.count > 1)
        for chunk in output.chunks.dropFirst() {
            let start = chunk.charRange.location
            #expect((attr.string as NSString).character(at: start - 1) == 0x000A)
        }
    }

    @Test("scroll chunks retain the publication-authored page backdrop")
    @MainActor
    func scrollChunksRetainPublicationAuthoredPageBackdrop() throws {
        let authoredColor = UIColor(red: 0x35 / 255, green: 0x2D / 255, blue: 0x2D / 255, alpha: 1)
        let authoredImage = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 48)).image { context in
            UIColor.white.withAlphaComponent(0.25).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 48))
        }
        let attr = NSAttributedString(
            string: (0..<40).map { "Authored page background paragraph \($0)." }.joined(separator: "\n"),
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.white,
            ]
        )

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 220,
            heightCap: 180,
            writingMode: .horizontal,
            pageBackgroundColor: authoredColor,
            pageBackgroundImage: authoredImage
        )

        try #require(output.chunks.count > 1)
        for chunk in output.chunks {
            let color = try #require(chunk.pageBackgroundColor)
            #expect(Self.bytes(of: color) == [53, 45, 45, 255])
            #expect(chunk.pageBackgroundImage === authoredImage)
        }
    }

    @Test("MathML attachments keep the same paged and scroll geometry")
    @MainActor
    func mathMLAttachmentsKeepTheSamePagedAndScrollGeometry() async throws {
        for width: CGFloat in [220, 390] {
            let epubURL = try await EPUBTestFixtures.makeArchive(
                entries: EPUBTestFixtures.mathMLTypography().entries
            )
            let session = try await PublicationSession.open(sourceURL: epubURL)
            let result = try await EPUBAttributedStringBuilder(
                session: session,
                renderSize: CGSize(width: width, height: 640)
            ).buildChapter(
                at: 0,
                settings: EPUBTestFixtures.renderSettings(),
                themeTextColor: .black,
                themeBackgroundColor: .white
            )
            let expectedSizes = EPUBTestFixtures.imageRunInfos(in: result.attributedString)
                .map(\.info)
                .filter { $0.source == "mathml:" }
                .map { CGSize(width: $0.drawWidth, height: $0.drawHeight) }
            let paged = await CoreTextPaginator().paginate(
                spineIndex: 0,
                attrStr: result.attributedString,
                imagePage: result.imagePage,
                pageBackgroundImage: result.pageBackgroundImage,
                anchorOffsets: result.anchorOffsets,
                renderSize: CGSize(width: width, height: 640),
                fontSize: EPUBTestFixtures.renderSettings().fontSize
            )
            let pagedSizes = (paged.inlineAttachments.values.flatMap { $0 }
                + paged.blockAttachments.values.flatMap { $0 })
                .filter { $0.sourceHref == "mathml:" }
                .map { $0.rect.size }
            let scroll = CoreTextChunkSlicer.slice(
                attributedString: result.attributedString,
                chapterIndex: 0,
                contentWidth: width,
                heightCap: 2_000
            )
            let scrollSizes = scroll.chunks
                .flatMap(\.attachments)
                .filter { $0.sourceHref == "mathml:" }
                .map { $0.rect.size }

            Self.expectSameSizes(expectedSizes, pagedSizes)
            Self.expectSameSizes(expectedSizes, scrollSizes)
        }
    }

    @Test("English EPUB attributes and offsets survive scroll slicing")
    @MainActor
    func englishEPUBAttributesAndOffsetsSurviveScrollSlicing() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(
            entries: EPUBTestFixtures.englishTypography().entries
        )
        let session = try await PublicationSession.open(sourceURL: epubURL)
        let settings = EPUBTestFixtures.renderSettings()
        let result = try await EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 220, height: 320)
        ).buildChapter(
            at: 0,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let source = result.attributedString.string as NSString
        let markerRange = source.range(of: "marker")
        let softHyphenOffset = source.range(of: "\u{00AD}").location
        let prepared = CoreTextPaginator.preparedAttributedString(
            result.attributedString,
            writingMode: .horizontal,
            fontSize: settings.fontSize,
            maxInlineAnnotationAdvance: nil
        )
        let output = CoreTextChunkSlicer.slice(
            attributedString: prepared,
            chapterIndex: 0,
            contentWidth: 220,
            heightCap: 120
        )

        try #require(markerRange.location != NSNotFound)
        try #require(softHyphenOffset != NSNotFound)
        try #require(output.chunks.count > 1)
        #expect(output.attributedString.length == result.attributedString.length)
        #expect((output.attributedString.string as NSString).character(at: softHyphenOffset) == 0x2060)
        #expect((output.attributedString.string as NSString).range(of: "marker").location == markerRange.location)
        #expect(
            output.attributedString.attribute(
                EPUBLanguageTypography.languageAttribute,
                at: markerRange.location,
                effectiveRange: nil
            ) as? String == "en-US"
        )
        #expect(
            output.attributedString.attribute(
                EPUBLanguageTypography.hyphenationPolicyAttribute,
                at: markerRange.location,
                effectiveRange: nil
            ) as? String == EPUBHyphenationPolicy.none.rawValue
        )
        #expect(HTMLAttributedStringBuilder.linkHref(
            at: source.range(of: "linked words").location,
            in: output.attributedString
        ) == "#target")

        var expectedStart = 0
        for chunk in output.chunks {
            #expect(chunk.charRange.location == expectedStart)
            expectedStart = chunk.charRange.location + chunk.charRange.length
        }
        #expect(expectedStart == output.attributedString.length)
        #expect(output.chunks.contains { chunk in
            NSLocationInRange(markerRange.location, NSRange(
                location: chunk.charRange.location,
                length: chunk.charRange.length
            ))
        })
    }

    @Test("scroll engine carries the chapter backdrop into sliced chunks")
    @MainActor
    func scrollEngineCarriesChapterBackdropIntoSlicedChunks() async throws {
        let authoredColor = UIColor(red: 0x35 / 255, green: 0x2D / 255, blue: 0x2D / 255, alpha: 1)
        let authoredImage = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 24)).image { _ in }
        let engine = CoreTextScrollEngine(
            builder: PageBackdropScrollTestBuilder(color: authoredColor, image: authoredImage),
            renderSettings: Self.renderSettings
        )

        await engine.start(initialChapter: 0, contentWidth: 220)

        let chunk = try #require(engine.chunks.first)
        let color = try #require(chunk.pageBackgroundColor)
        #expect(Self.bytes(of: color) == [53, 45, 45, 255])
        #expect(chunk.pageBackgroundImage === authoredImage)
    }

    @Test("scroll backdrop repeats at viewport-sized intervals without stretching a tall chapter")
    @MainActor
    func scrollBackdropUsesViewportSizedTiles() {
        let tiles = CoreTextChunkBackdropView.backgroundTileRects(
            in: CGRect(x: 0, y: 0, width: 390, height: 2_000),
            viewportSize: CGSize(width: 390, height: 844),
            axis: .vertical
        )

        #expect(tiles.count == 3)
        #expect(tiles.map(\.minY) == [0, 844, 1_688])
        #expect(tiles.allSatisfy { $0.size == CGSize(width: 390, height: 844) })
    }

    @Test("styled EPUB scroll chunks keep block renderables and continuous ranges")
    func styledEPUBScrollChunksKeepBlockRenderables() async {
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 4,
            paragraphSpacing: 10,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 240
        )
        let html = """
        <html>
        <head>
        <style>
        h1 { background-color: #eeeeee; border-left: #336699 solid 4px; padding: 4px; }
        p { margin: 0 0 1em 0; text-indent: 2em; }
        </style>
        </head>
        <body>
        <h1>Project Hail Mary</h1>
        <p>This English paragraph should keep its natural spacing in scroll mode instead of being stretched like CJK text.</p>
        <p>被討厭的勇氣測試段落應該保留標題和段落樣式。</p>
        </body>
        </html>
        """

        let attr = await EPUBTestFixtures.renderIR(html: html, config: config)
        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 240,
            heightCap: 180
        )

        #expect(output.chunks.contains { !$0.blockRenderables.isEmpty })
        #expect(output.chunks.first?.charRange.location == 0)
        for pair in zip(output.chunks, output.chunks.dropFirst()) {
            #expect(pair.0.charRange.location + pair.0.charRange.length == pair.1.charRange.location)
        }
        if let last = output.chunks.last {
            #expect(last.charRange.location + last.charRange.length == attr.length)
        }
    }

    @Test("scroll chunks wrap text around CSS float images")
    func scrollChunksWrapTextAroundCSSFloatImages() async throws {
        let floatImage = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 120)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 120))
        }
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { href in
            href == "float.png" ? floatImage : nil
        }
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.2,
            lineSpacing: 0,
            paragraphSpacing: 0,
            firstLineIndent: 0,
            textColor: .black,
            backgroundColor: .white,
            renderWidth: 240
        )
        let html = """
        <html>
        <body>
        <img style="float: left; width: 100px;" src="float.png" alt="float"/>
        <p style="margin: 0; text-indent: 0;">Wrapped text should start beside the floated image and keep flowing beside it for several lines before returning to the full width content column.</p>
        </body>
        </html>
        """

        let attr = await EPUBTestFixtures.renderIR(html: html, config: config, builder: builder)
        #expect(CoreTextPaginator.floatMarkers(in: attr).count == 1)

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 240,
            heightCap: 360
        )

        let chunk = try #require(output.chunks.first)
        let attachment = try #require(chunk.attachments.first { $0.sourceHref == "float.png" })
        #expect(attachment.rect.minX < 1)
        #expect(abs(attachment.rect.width - 100) < 1)

        let frame = try #require(chunk.frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let hasIndentedWrappedLine = zip(lines, origins).contains { line, origin in
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.location >= 0, lineRange.length > 0 else { return false }
            let text = (attr.string as NSString).substring(
                with: NSRange(location: lineRange.location, length: min(lineRange.length, attr.length - lineRange.location))
            )
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && origin.x >= attachment.rect.maxX - 1
        }
        #expect(hasIndentedWrappedLine)
    }

    @Test("scroll video media taps embed inline instead of presenting modal")
    @MainActor
    func scrollVideoMediaTapsEmbedInlineInsteadOfPresentingModal() async throws {
        let html = """
        <html><body>
        <video src="file:///tmp/yuedu-scroll-video-test.mp4" title="Inline video" style="width: 160px; height: 90px;"></video>
        <p>Text after video.</p>
        </body></html>
        """
        let engine = CoreTextScrollEngine(
            builder: HTMLScrollTestBuilder(html: html, renderWidth: 240),
            renderSettings: Self.renderSettings
        )
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .vertical,
            horizontalInset: 12,
            verticalInset: 20,
            backgroundColor: .white
        )
        controller.setInitialPosition(chapter: 0, charOffset: 0)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let collectionView = try #require(Self.firstCollectionView(in: controller.view))
        for _ in 0..<50 where engine.chunks.isEmpty || collectionView.numberOfItems(inSection: 0) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }
        controller.view.layoutIfNeeded()
        try #require(engine.chunks.first?.attachments.contains { $0.mediaAttachment?.kind == .video } == true)

        let video = try #require(engine.chunks.first?.attachments.first { $0.mediaAttachment?.kind == .video }?.mediaAttachment)
        controller.handleMediaTap(video)

        #expect(controller.presentedViewController == nil)
        #expect(controller.inlineVideoControllerCountForTesting == 1)
        EPUBVideoPlaybackManager.shared.stopAll()
        window.isHidden = true
    }

    @Test("actual Project Hail Mary EPUB builds IR scroll chunks")
    @MainActor
    func actualProjectHailMaryBuildsIRScrollChunks() async throws {
        guard let sourceURL = Self.fixtureURL(Self.projectHailMaryPath) else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let chapterIndex = try #require(session.chapterIndex(for: "text/part0005.html"))
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: Self.fixtureRenderSize
        )

        let result = try await builder.buildChapter(
            at: chapterIndex,
            settings: Self.renderSettings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        #expect(result.attributedString.string.contains("What’s two plus two"))

        let output = CoreTextChunkSlicer.slice(
            attributedString: result.attributedString,
            chapterIndex: chapterIndex,
            contentWidth: Self.fixtureContentWidth,
            heightCap: 420
        )

        #expect(output.chunks.count > 1)
        #expect(output.chunks.contains { !$0.blockRenderables.isEmpty })
        Self.expectContinuousChunks(output.chunks, totalLength: result.attributedString.length)
    }

    @Test("actual Hated Courage EPUB keeps title in vertical IR scroll chunks")
    @MainActor
    func actualHatedCourageKeepsTitleInVerticalIRScrollChunks() async throws {
        guard let sourceURL = Self.fixtureURL(Self.hatedCouragePath) else { return }
        let session = try await PublicationSession.open(sourceURL: sourceURL)
        let chapterIndex = try #require(session.chapterIndex(for: "text/part0009.html"))
        let settings = Self.makeRenderSettings(writingMode: .verticalRTL)
        let builder = EPUBAttributedStringBuilder(
            session: session,
            renderSize: Self.fixtureRenderSize
        )

        let result = try await builder.buildChapter(
            at: chapterIndex,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        #expect(result.attributedString.string.contains("第一夜"))
        #expect(result.attributedString.string.contains("我们的不幸是谁的错"))

        let output = CoreTextChunkSlicer.slice(
            attributedString: result.attributedString,
            chapterIndex: chapterIndex,
            contentWidth: Self.fixtureContentHeight,
            heightCap: Self.fixtureContentWidth,
            writingMode: .verticalRTL
        )

        #expect(!output.chunks.isEmpty)
        for (index, chunk) in output.chunks.enumerated() {
            #expect(chunk.writingMode == .verticalRTL)
            if index == output.chunks.indices.last {
                #expect(chunk.width <= Self.fixtureContentWidth)
            } else {
                #expect(chunk.width == Self.fixtureContentWidth)
            }
            #expect(chunk.height == Self.fixtureContentHeight)
        }
        Self.expectContinuousChunks(output.chunks, totalLength: result.attributedString.length)
    }

    @Test("vertical scroll slicing produces horizontal RTL chunks")
    func verticalScrollSlicingProducesHorizontalChunks() {
        let attr = NSAttributedString(
            string: (0..<120)
                .map { _ in "被討厭的勇氣測試文字，直排欄位應該由右往左連續前進。" }
                .joined(separator: "\n"),
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.black,
            ]
        )

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 320,
            heightCap: 480,
            writingMode: .verticalRTL
        )

        #expect(!output.chunks.isEmpty)
        for (index, chunk) in output.chunks.enumerated() {
            #expect(chunk.writingMode == .verticalRTL)
            if index == output.chunks.indices.last {
                #expect(chunk.width <= 480)
            } else {
                #expect(chunk.width == 480)
            }
            #expect(chunk.height == 320)
        }
    }

    @Test("vertical RTL scroll terminal chunk shrinks to used columns")
    func verticalRTLScrollTerminalChunkShrinksToUsedColumns() throws {
        let attr = NSAttributedString(
            string: "短章節，只有幾欄。",
            attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.black,
            ]
        )

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 320,
            heightCap: 480,
            writingMode: .verticalRTL
        )

        let chunk = try #require(output.chunks.first)
        #expect(chunk.writingMode == .verticalRTL)
        #expect(chunk.width < 480)
        #expect(chunk.height == 320)
    }

    private static let renderSettings = makeRenderSettings()
    private static let fixtureRenderSize = CGSize(width: 440, height: 956)
    private static let fixtureContentWidth: CGFloat = 392
    private static let fixtureContentHeight: CGFloat = 852
    private static let projectHailMaryPath = "/Users/zhangruilin/Desktop/Test document/EPUB Format/Project Hail Mary (Andy Weir) (z-library.sk, 1lib.sk, z-lib.sk).epub"
    private static let hatedCouragePath = "/Users/zhangruilin/Desktop/Test document/EPUB Format/被讨厌的勇气：“自我启发之父”阿德勒的哲学课 = 嫌われる勇気：自己啓発の源流「アドラー」の教え ([日] 岸见一郎，[日] 古贺史健 著；渠海霞 译) (z-library.sk, 1lib.sk, z-lib.sk).epub"

    private static func fixtureURL(_ path: String) -> URL? {
        FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private static func expectContinuousChunks(_ chunks: [CoreTextChunk], totalLength: Int) {
        guard let first = chunks.first else {
            #expect(Bool(false))
            return
        }
        #expect(first.charRange.location == 0)
        for pair in zip(chunks, chunks.dropFirst()) {
            #expect(pair.0.charRange.location + pair.0.charRange.length == pair.1.charRange.location)
        }
        if let last = chunks.last {
            #expect(last.charRange.location + last.charRange.length == totalLength)
        }
    }

    private static func expectSameSizes(_ expected: [CGSize], _ actual: [CGSize]) {
        let expected = expected.sorted {
            $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width
        }
        let actual = actual.sorted {
            $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width
        }
        #expect(actual.count == expected.count)
        for (expectedSize, actualSize) in zip(expected, actual) {
            #expect(abs(actualSize.width - expectedSize.width) <= 0.5)
            #expect(abs(actualSize.height - expectedSize.height) <= 0.5)
        }
    }

    private static func firstCollectionView(in view: UIView) -> UICollectionView? {
        if let collectionView = view as? UICollectionView {
            return collectionView
        }
        for subview in view.subviews {
            if let collectionView = firstCollectionView(in: subview) {
                return collectionView
            }
        }
        return nil
    }

    private static func alpha(of color: UIColor) -> CGFloat {
        var alpha: CGFloat = 0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return alpha
    }

    private static func bytes(of color: UIColor) -> [Int] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { Int(round($0 * 255)) }
    }

    private static func makeRenderSettings(writingMode: ReaderWritingMode = .horizontal) -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.0,
            lineSpacing: 0,
            paragraphSpacing: 0,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: writingMode
        )
    }

    private static let longChapter = (0..<80)
        .map { "Paragraph \($0). A long English line for scroll chunk warmup and layout measurement." }
        .joined(separator: "\n")

    private static let longVerticalChapter = (0..<160)
        .map { _ in "直排測試文字，應該從右邊開始呈現，並且往左連續前進。" }
        .joined(separator: "\n")

    private static let longTXT = (0..<160)
        .map { "TXT paragraph \($0). First scroll switch should slice and display this text without relying on an already attached collection view." }
        .joined(separator: "\n")
}

private struct StaticScrollTestBuilder: AttributedStringBuilding {
    let chapters: [String]

    var chapterCount: Int { chapters.count }

    func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
    func chapterSourceHref(at index: Int) -> String? { "chapter-\(index).xhtml" }
    func chapterDataSize(at index: Int) async -> Int { chapters[index].utf8.count }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: chapters[index],
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}

private struct HTMLScrollTestBuilder: AttributedStringBuilding {
    let html: String
    let renderWidth: CGFloat

    var chapterCount: Int { 1 }

    func chapterTitle(at index: Int) -> String { "HTML" }
    func chapterSourceHref(at index: Int) -> String? { "chapter.xhtml" }
    func chapterDataSize(at index: Int) async -> Int { html.utf8.count }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        let builder = HTMLAttributedStringBuilder()
        let result = await builder.build(
            html: html,
            config: HTMLAttributedStringBuilder.Config(
                fontSize: settings.fontSize,
                lineHeightMultiple: settings.lineHeightMultiple,
                lineSpacing: settings.lineSpacing,
                paragraphSpacing: settings.paragraphSpacing,
                firstLineIndent: 0,
                textColor: themeTextColor,
                backgroundColor: themeBackgroundColor,
                renderWidth: renderWidth,
                writingMode: settings.writingMode
            )
        )
        return AttributedChapterBuildResult(
            attributedString: result.attributedString,
            imagePage: result.imagePage,
            pageBackgroundImage: result.pageBackgroundImage,
            anchorOffsets: result.anchorOffsets
        )
    }
}

private struct DelayedScrollTestBuilder: AttributedStringBuilding {
    let chapters: [String]
    let delayNanoseconds: UInt64

    var chapterCount: Int { chapters.count }

    func chapterTitle(at index: Int) -> String { "Chapter \(index)" }
    func chapterSourceHref(at index: Int) -> String? { "chapter-\(index).xhtml" }
    func chapterDataSize(at index: Int) async -> Int { chapters[index].utf8.count }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: chapters[index],
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}

private struct ImagePageScrollTestBuilder: AttributedStringBuilding {
    let image: UIImage

    var chapterCount: Int { 1 }

    func chapterTitle(at index: Int) -> String { "Cover" }
    func chapterSourceHref(at index: Int) -> String? { "cover.xhtml" }
    func chapterDataSize(at index: Int) async -> Int { 1 }
    func chapterIndex(for href: String) -> Int? { nil }
    func cssResourceHrefs() -> [String] { [] }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: "\u{FFFC}",
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: HTMLAttributedStringBuilder.ImagePage(source: "cover.jpg", image: image),
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}

private struct PageBackdropScrollTestBuilder: AttributedStringBuilding {
    let color: UIColor
    let image: UIImage

    var chapterCount: Int { 1 }

    func chapterTitle(at index: Int) -> String { "Backdrop" }
    func chapterSourceHref(at index: Int) -> String? { "backdrop.xhtml" }
    func chapterDataSize(at index: Int) async -> Int { 1 }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        AttributedChapterBuildResult(
            attributedString: NSAttributedString(
                string: "Backdrop chapter",
                attributes: [
                    .font: UIFont.systemFont(ofSize: settings.fontSize),
                    .foregroundColor: themeTextColor,
                ]
            ),
            imagePage: nil,
            pageBackgroundImage: image,
            pageBackgroundColor: color,
            anchorOffsets: [:]
        )
    }
}
