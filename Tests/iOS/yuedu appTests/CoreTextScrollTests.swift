@testable import YueduCoreText
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
    @MainActor
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

    @Test("night mode overrides custom reader colors and light mode restores them")
    @MainActor
    func nightModeTemporarilyOverridesCustomReaderColors() {
        let previousPreset = AppearanceThemePreset.activeReaderTheme
        defer { AppearanceThemePreset.activeReaderTheme = previousPreset }
        AppearanceThemePreset.activeReaderTheme = AppearanceThemePreset.preset(
            from: AppearanceCustomTheme(
                name: "Custom Reader",
                backgroundHex: 0x123456,
                textHex: 0x654321,
                barHex: 0x234567,
                accentHex: 0x345678,
                dialogueHex: 0x456789
            )
        )

        #expect(Self.bytes(of: ReaderTheme.white.uiBackgroundColor) == [18, 52, 86, 255])
        #expect(Self.bytes(of: ReaderTheme.night.uiBackgroundColor) == [0, 0, 0, 255])
        #expect(Self.bytes(of: ReaderTheme.night.uiTextColor) == [217, 217, 217, 255])
        #expect(Self.bytes(of: ReaderTheme.night.uiBarColor) == [26, 26, 26, 255])
        #expect(Self.bytes(of: ReaderTheme.white.uiBackgroundColor) == [18, 52, 86, 255])
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
            sideInsets: .init(left: 12, right: 12),
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
            sideInsets: .init(left: 12, right: 12),
            verticalInset: 20,
            backgroundColor: .white
        )

        #expect(controller.scrollAxis == .horizontalRTL)
    }

    @Test("a theme change swaps the colors and keeps every other render setting")
    @MainActor
    func themeChangeKeepsNonColorRenderSettings() {
        var settings = Self.makeRenderSettings()
        settings.dialogueBubbleStyle.isEnabled.toggle()
        settings.textConversion = .toTraditional
        settings.translation = ReaderTranslationPresentation(mode: .bilingual)
        settings.bookID = UUID()
        settings.bottomJustify = true
        settings.displayScale = 3
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: ["主題切換"]),
            renderSettings: settings
        )

        engine.applyThemeChange(textColor: .white, backgroundColor: .black)

        var expected = settings
        expected.textColor = .white
        expected.backgroundColor = .black
        #expect(engine.renderSettings == expected)
    }

    @Test("reused chunk cell immediately discards its previous rendered contents")
    @MainActor
    func reusedChunkCellDiscardsPreviousRenderedContents() throws {
        let cell = CoreTextChunkCollectionCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        cell.drawView.layer.contents = image.cgImage

        cell.prepareForReuse()

        #expect(cell.drawView.layer.contents == nil)
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
            sideInsets: .init(left: 24, right: 24),
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
            sideInsets: .init(left: 24, right: 24),
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
            sideInsets: .init(left: 12, right: 12),
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

        // Bounded: a 160-paragraph chapter takes over a second to slice on an iOS 17 simulator,
        // where a fixed half second ran out before the first chunk existed.
        for _ in 0..<500 where !engine.isReady || controller.positionForPersistence() == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }

        let collectionView = try #require(Self.firstCollectionView(in: controller.view))
        #expect(engine.isReady)
        #expect(collectionView.contentSize.width > collectionView.bounds.width)
        let minOffsetX = -collectionView.adjustedContentInset.left
        let maxOffsetX = max(minOffsetX, collectionView.contentSize.width - collectionView.bounds.width + collectionView.adjustedContentInset.right)
        #expect(collectionView.contentOffset.x >= minOffsetX - 0.5)
        #expect(collectionView.contentOffset.x <= maxOffsetX + 0.5)
        window.isHidden = true
    }

    /// What the reader sees, not where the offset is: the test above passed while a TXT chapter
    /// opened at 0% on its *last* columns (2026-10-15). Both chapter shapes: one chunk wider than
    /// the screen, as a short TXT chapter is, and several full-width chunks.
    @Test("horizontal RTL scroll opens on the chapter's first column, and says so",
          arguments: [false, true])
    @MainActor
    func horizontalRTLOpensOnFirstColumn(longChapter: Bool) async throws {
        let settings = Self.makeRenderSettings(writingMode: .verticalRTL)
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(
                chapters: [longChapter ? Self.longVerticalChapter : Self.shortVerticalChapter]
            ),
            renderSettings: settings
        )
        let inset: CGFloat = 24
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .horizontalRTL,
            sideInsets: .init(left: inset, right: inset),
            verticalInset: 72,
            backgroundColor: .white
        )
        controller.bottomMargin = 32
        controller.setInitialPosition(chapter: 0, charOffset: 0)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        // Bounded: a 160-paragraph chapter takes over a second to slice on an iOS 17 simulator.
        for _ in 0..<500 where controller.positionForPersistence() == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }
        let collectionView = try #require(Self.firstCollectionView(in: controller.view))
        #expect(collectionView.contentSize.width > collectionView.bounds.width)
        #expect((engine.chunks.count > 1) == longChapter)

        let chunk = try #require(engine.chunks.first)
        chunk.materializeFrameIfNeeded()
        let frame = try #require(chunk.frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let firstColumn = try #require(origins.first)
        let cell = try #require(
            collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? CoreTextChunkCollectionCell
        )
        let drawn = cell.drawView.convert(CGPoint(x: firstColumn.x, y: chunk.height / 2), to: window)
        let geometry = "offset=\(collectionView.contentOffset.x) content=\(collectionView.contentSize.width) "
            + "chunk=\(chunk.width) column=\(firstColumn.x) collection→window x+1=\(collectionView.convert(CGPoint(x: 1, y: 0), to: window).x - collectionView.convert(CGPoint.zero, to: window).x) "
            + "cell→collection x+1=\(cell.convert(CGPoint(x: 1, y: 0), to: collectionView).x - cell.convert(CGPoint.zero, to: collectionView).x)"
        // The first column sits against the right-hand margin: on screen, and within a couple
        // of column widths of where the text begins.
        #expect(drawn.x <= window.bounds.width - inset, "\(drawn.x) \(geometry)")
        #expect(drawn.x >= window.bounds.width - inset - 2 * settings.fontSize, "\(drawn.x) \(geometry)")

        // And what gets saved is that column, not the one at the far edge of the screen.
        let saved = try #require(controller.positionForPersistence())
        let firstLine = CTLineGetStringRange(lines[0])
        #expect(saved.charOffset < firstLine.location + firstLine.length, "saved \(saved.charOffset) \(geometry)")
    }

    /// A later chapter's first chunk carries the gap that parts it from the chapter before, on its
    /// right — before its text. Opening at that chapter's start steps past the gap.
    @Test("horizontal RTL restore to a later chapter lands on its first column, past the gap")
    @MainActor
    func horizontalRTLRestoreToLaterChapterSkipsTheGap() async throws {
        let settings = Self.makeRenderSettings(writingMode: .verticalRTL)
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: [Self.shortVerticalChapter, Self.shortVerticalChapter]),
            renderSettings: settings
        )
        let inset: CGFloat = 24
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .horizontalRTL,
            sideInsets: .init(left: inset, right: inset),
            verticalInset: 72,
            backgroundColor: .white
        )
        controller.bottomMargin = 32
        controller.setInitialPosition(chapter: 1, charOffset: 0)

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        // Until the chapter before has loaded in front — only then is there a gap to step past —
        // and the restore that follows the insertion has run: it waits for the batch update to
        // finish, and until then the unchanged offset shows the inserted chapter.
        for _ in 0..<500 where engine.chapterRanges[0] == nil
            || controller.positionForPersistence()?.spineIndex != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }
        let collectionView = try #require(Self.firstCollectionView(in: controller.view))
        try #require(engine.chapterRanges[0] != nil)
        let row = try #require(engine.chapterRanges[1]?.first)
        #expect(row > 0)

        let chunk = engine.chunks[row]
        chunk.materializeFrameIfNeeded()
        let frame = try #require(chunk.frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        let firstColumn = try #require(origins.first)
        let cell = try #require(
            collectionView.cellForItem(at: IndexPath(item: row, section: 0)) as? CoreTextChunkCollectionCell
        )
        let drawn = cell.drawView.convert(CGPoint(x: firstColumn.x, y: chunk.height / 2), to: window)
        let geometry = "offset=\(collectionView.contentOffset.x) row=\(row) chunk=\(chunk.width) column=\(firstColumn.x)"
        #expect(drawn.x <= window.bounds.width - inset, "\(drawn.x) \(geometry)")
        #expect(drawn.x >= window.bounds.width - inset - 2 * settings.fontSize, "\(drawn.x) \(geometry)")

        let saved = try #require(controller.positionForPersistence())
        let firstLine = CTLineGetStringRange(lines[0])
        #expect(saved.spineIndex == 1, "\(geometry)")
        #expect(saved.charOffset < firstLine.location + firstLine.length, "saved \(saved.charOffset) \(geometry)")
    }

    /// 下一章 and the table of contents re-slice at the chapter's start: it is shown alone, and the
    /// chapters either side of it arrive afterwards, one of them in front of it. UIKit carries the
    /// cell showing its first chunk across that insertion without binding it again — bound as the
    /// first item, with no gap ahead of it, it drew the chapter a gap's width right of the margin,
    /// the title cut off by the screen's edge (2026-10-16).
    @Test("horizontal RTL jump to the next chapter lands on its first column")
    @MainActor
    func horizontalRTLJumpToNextChapterLandsOnItsFirstColumn() async throws {
        let inset: CGFloat = 24
        let fontSize = Self.makeRenderSettings(writingMode: .verticalRTL).fontSize
        // Mid-chapter, as 下一章 is usually pressed: the jump moves the offset, and moving it is
        // what asks for the chapters either side.
        let reader = try await Self.openVertical(
            [Self.longVerticalChapter, Self.longVerticalChapter, Self.longVerticalChapter], at: 1000,
            sides: .init(left: inset, right: inset)
        )
        defer { reader.window.isHidden = true }

        reader.controller.requestReslice(at: 1)
        // Bounded: both neighbours slice in the background, over a second each on an iOS 17 simulator.
        for _ in 0..<1000 where reader.engine.chapterRanges[0] == nil || reader.engine.chapterRanges[2] == nil
            || reader.controller.positionForPersistence()?.spineIndex != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
            reader.controller.view.layoutIfNeeded()
        }
        let row = try #require(reader.engine.chapterRanges[1]?.first)
        #expect(row > 0)
        let chunk = try #require(reader.engine.chunks[row].legacyChunk)
        let first = try #require(try Self.columns(of: chunk).first)
        let cell = try #require(
            reader.collectionView.cellForItem(at: IndexPath(item: row, section: 0)) as? CoreTextChunkCollectionCell
        )
        let drawn = cell.drawView.convert(CGPoint(x: first.origin.x, y: chunk.height / 2), to: reader.window)
        let geometry = "offset=\(reader.collectionView.contentOffset.x) row=\(row) "
            + "drawView=\(cell.drawView.frame) cell=\(cell.bounds.size)"
        #expect(drawn.x <= reader.window.bounds.width - inset, "\(drawn.x) \(geometry)")
        #expect(drawn.x >= reader.window.bounds.width - inset - 2 * fontSize, "\(drawn.x) \(geometry)")

        let saved = try #require(reader.controller.positionForPersistence())
        let firstLine = CTLineGetStringRange(first.line)
        #expect(saved.spineIndex == 1, "\(geometry)")
        #expect(saved.charOffset < firstLine.location + firstLine.length, "saved \(saved.charOffset) \(geometry)")
    }

    /// A book left mid-chapter reopens on the column the reader left, not on the first column of
    /// the chunk holding it — which put them back up to a chunk's width, the footer still reading
    /// where they had been (2026-10-15). And saving reads that column back, so leaving and
    /// reopening goes nowhere: also for a column too short to reach the screen's middle (「好。」),
    /// which saving used to miss and record as the chunk's start.
    @Test("horizontal RTL reopens on the column holding the position, and saves that column",
          arguments: [false, true])
    @MainActor
    func horizontalRTLRestoresTheColumnNotTheChunk(shortColumn: Bool) async throws {
        let chapter = shortColumn ? Self.verticalChapterWithShortColumns : Self.longVerticalChapter
        let inset: CGFloat = 24

        // A column in the middle of the second chunk: clear of both ends of the chapter, so the
        // scroll range cannot be what holds it at the margin.
        let probe = try await Self.openVertical([chapter], at: 0, sides: .init(left: inset, right: inset))
        let chunk = try #require(probe.engine.chunks.count >= 2 ? probe.engine.chunks[1].legacyChunk : nil)
        try #require(chunk.width / 2 > probe.window.bounds.width, "chunk \(chunk.width)")
        let lines = try Self.columns(of: chunk)
        let candidates = lines.indices.filter { (CTLineGetStringRange(lines[$0].line).length <= 5) == shortColumn }
        let middle = try #require(candidates.min { abs($0 - lines.count / 2) < abs($1 - lines.count / 2) })
        let target = CTLineGetStringRange(lines[middle].line).location + 1
        probe.window.isHidden = true

        let reader = try await Self.openVertical([chapter], at: target, sides: .init(left: inset, right: inset))
        defer { reader.window.isHidden = true }
        let column = try Self.column(holding: target, in: reader)
        #expect(abs(column.rightEdge - (reader.window.bounds.width - inset)) <= 1,
                "column \(column) offset=\(reader.collectionView.contentOffset.x)")
        let saved = try #require(reader.controller.positionForPersistence())
        #expect(saved == CoreTextReadingPosition(spineIndex: 0, charOffset: column.start), "target \(target)")

        let reopened = try await Self.openVertical([chapter], at: saved.charOffset, sides: .init(left: inset, right: inset))
        defer { reopened.window.isHidden = true }
        let again = try Self.column(holding: saved.charOffset, in: reopened)
        #expect(abs(again.rightEdge - (reopened.window.bounds.width - inset)) <= 1, "column \(again)")
        #expect(reopened.controller.positionForPersistence() == saved)
    }

    /// A folded iPhone Duo has its status bar down the right side only, so the two margins
    /// differ. Vertical writing starts at the right-hand one: at the chapter's start, where the
    /// collection's own content inset holds it and UIKit mirrors that inset, and when reopening
    /// mid-chapter, where the reading edge places it.
    @Test("horizontal RTL lines its columns up on the right-hand margin when the two margins differ")
    @MainActor
    func horizontalRTLUsesTheRightHandMarginWhenTheMarginsDiffer() async throws {
        let sides = ReaderSideInsets(left: 8, right: 70)
        let fontSize = Self.makeRenderSettings(writingMode: .verticalRTL).fontSize

        let start = try await Self.openVertical([Self.longVerticalChapter], at: 0, sides: sides)
        let margin = start.window.bounds.width - sides.right
        let first = try Self.column(holding: 0, in: start)
        #expect(first.rightEdge <= margin + 1 && first.rightEdge >= margin - 2 * fontSize,
                "first column \(first) offset=\(start.collectionView.contentOffset.x)")
        // A column in the middle of the second chunk: clear of both ends of the chapter, so the
        // scroll range cannot be what holds it at the margin.
        let chunk = try #require(start.engine.chunks.count >= 2 ? start.engine.chunks[1].legacyChunk : nil)
        try #require(chunk.width / 2 > start.window.bounds.width, "chunk \(chunk.width)")
        let lines = try Self.columns(of: chunk)
        let target = CTLineGetStringRange(lines[lines.count / 2].line).location + 1
        start.window.isHidden = true

        let reader = try await Self.openVertical([Self.longVerticalChapter], at: target, sides: sides)
        defer { reader.window.isHidden = true }
        let column = try Self.column(holding: target, in: reader)
        #expect(abs(column.rightEdge - margin) <= 1,
                "column \(column) offset=\(reader.collectionView.contentOffset.x)")
    }

    /// The same folded iPhone Duo in horizontal writing: the text starts at the left margin and
    /// fills the width between the two.
    @Test("vertical scroll lays the text out between two different side margins")
    @MainActor
    func verticalScrollLaysOutBetweenDifferentSideMargins() async throws {
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: [Self.longChapter]),
            renderSettings: Self.makeRenderSettings()
        )
        let sides = ReaderSideInsets(left: 8, right: 70)
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .vertical,
            sideInsets: sides,
            verticalInset: 20,
            backgroundColor: .white
        )
        controller.setInitialPosition(chapter: 0, charOffset: 0)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 466, height: 678)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        for _ in 0..<500 where !engine.isReady || controller.positionForPersistence() == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }

        let collectionView = try #require(Self.firstCollectionView(in: controller.view))
        let cell = try #require(
            collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? CoreTextChunkCollectionCell
        )
        let drawn = cell.drawView.convert(cell.drawView.bounds, to: window)
        #expect(engine.contentWidth == window.bounds.width - sides.left - sides.right)
        #expect(abs(drawn.minX - sides.left) <= 0.5, "\(drawn)")
        #expect(abs(drawn.maxX - (window.bounds.width - sides.right)) <= 0.5, "\(drawn)")
    }

    private struct VerticalReader {
        let controller: CoreTextCollectionScrollViewController
        let engine: CoreTextScrollEngine
        let window: UIWindow
        let collectionView: UICollectionView
    }

    /// A vertical-writing TXT reader on a phone-sized screen, opened at `charOffset` of the first
    /// chapter, once its restore has run.
    @MainActor
    private static func openVertical(_ chapters: [String], at charOffset: Int, sides: ReaderSideInsets) async throws -> VerticalReader {
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: chapters),
            renderSettings: makeRenderSettings(writingMode: .verticalRTL)
        )
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .horizontalRTL,
            sideInsets: sides,
            verticalInset: 72,
            backgroundColor: .white
        )
        controller.bottomMargin = 32
        controller.setInitialPosition(chapter: 0, charOffset: charOffset)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Bounded: a 160-paragraph chapter takes over a second to slice on an iOS 17 simulator.
        for _ in 0..<500 where !engine.isReady || controller.positionForPersistence() == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            controller.view.layoutIfNeeded()
        }
        let collectionView = try #require(firstCollectionView(in: controller.view))
        return VerticalReader(controller: controller, engine: engine, window: window, collectionView: collectionView)
    }

    @MainActor
    private static func columns(of chunk: CoreTextChunk) throws -> [(line: CTLine, origin: CGPoint)] {
        chunk.materializeFrameIfNeeded()
        let frame = try #require(chunk.frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &origins)
        return Array(zip(lines, origins))
    }

    /// Where the column holding `charOffset` has its right edge on screen, and the character it
    /// starts with.
    @MainActor
    private static func column(holding charOffset: Int, in reader: VerticalReader) throws -> (rightEdge: CGFloat, start: Int) {
        let row = try #require(reader.engine.chunkIndex(forChapter: 0, charOffset: charOffset))
        let chunk = try #require(reader.engine.chunks[row].legacyChunk)
        let column = try #require(try columns(of: chunk).first {
            let range = CTLineGetStringRange($0.line)
            return charOffset < range.location + range.length
        })
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(column.line, &ascent, &descent, nil)
        let right = max(column.origin.x - descent, column.origin.x + ascent)
        let cell = try #require(
            reader.collectionView.cellForItem(at: IndexPath(item: row, section: 0)) as? CoreTextChunkCollectionCell
        )
        let drawn = cell.drawView.convert(CGPoint(x: right, y: chunk.height / 2), to: reader.window)
        return (drawn.x, CTLineGetStringRange(column.line).location)
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
            sideInsets: .init(left: 12, right: 12),
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

    @Test("scroll controller applies a visible refresh commit")
    @MainActor
    func scrollControllerAppliesVisibleRefreshCommit() async throws {
        let engine = CoreTextScrollEngine(
            builder: StaticScrollTestBuilder(chapters: [Self.longChapter]),
            renderSettings: Self.renderSettings
        )
        let controller = CoreTextCollectionScrollViewController(
            engine: engine,
            axis: .vertical,
            sideInsets: .init(left: 12, right: 12),
            verticalInset: 20,
            backgroundColor: .white
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.setInitialPosition(chapter: 0, charOffset: 0)
        controller.loadViewIfNeeded()

        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        for _ in 0..<100 where !engine.isReady {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(engine.isReady)

        var appliedTransactionIDs: [UInt64] = []
        controller.applyVisibleRefresh(
            ReaderVisibleRefreshCommit(
                transactionID: 9,
                mode: .scroll,
                position: CoreTextReadingPosition(spineIndex: 0, charOffset: 40)
            )
        ) { transactionID, outcome in
            if outcome == .applied {
                appliedTransactionIDs.append(transactionID)
            }
        }

        for _ in 0..<100 where appliedTransactionIDs.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(appliedTransactionIDs == [9])
        #expect(controller.lastAppliedRefreshTransactionID == 9)
        #expect(engine.isReady)
        window.isHidden = true
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
            sideInsets: .init(left: 12, right: 12),
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

        _ = await resliceTask.value
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

    /// 《红楼梦》回目扉页: a title and two footnotes over a full-bleed `background-image` on
    /// `<body>`. The backdrop is painted into the chunk's own box, so before the padding the
    /// chapter's chunk was only as tall as those few lines and the artwork was cropped to the
    /// top third — paged mode paints the same image across a whole page.
    @Test("a short chapter carrying a backdrop image is padded to one viewport")
    func shortBackdropChapterFillsOneViewport() throws {
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 48)).image { _ in }
        let attr = NSAttributedString(
            string: "第十四回\n林如海捐馆扬州城\n贾宝玉路谒北静王\n",
            attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black]
        )

        let unpadded = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 220,
            pageBackgroundImage: backdrop
        )
        let padded = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 220,
            pageBackgroundImage: backdrop,
            minimumBackdropExtent: 844
        )

        let short = try #require(unpadded.chunks.first)
        try #require(short.height < 844)
        #expect(padded.chunks.count == 1)
        let filled = try #require(padded.chunks.first)
        #expect(filled.height >= 844)
        // Height only: the chapter's characters must be untouched, or progress, TTS
        // and selection would all shift with the padding.
        #expect(filled.charRange.location == short.charRange.location)
        #expect(filled.charRange.length == short.charRange.length)
        #expect(filled.charRange.length == attr.length)
    }

    @Test("a short chapter without a backdrop image keeps its natural height")
    func shortChapterWithoutBackdropKeepsNaturalHeight() throws {
        let attr = NSAttributedString(
            string: "第十四回\n林如海捐馆扬州城\n",
            attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black]
        )

        let output = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 220,
            pageBackgroundColor: .white,
            minimumBackdropExtent: 844
        )

        let chunk = try #require(output.chunks.first)
        #expect(chunk.height < 844)
    }

    @Test("a chapter already longer than one viewport is not padded")
    func longBackdropChapterIsNotPadded() throws {
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 48)).image { _ in }
        let attr = NSAttributedString(
            string: (0..<40).map { "Authored page background paragraph \($0)." }.joined(separator: "\n"),
            attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black]
        )

        func totalHeight(minimumBackdropExtent: CGFloat) -> CGFloat {
            CoreTextChunkSlicer.slice(
                attributedString: attr,
                chapterIndex: 0,
                contentWidth: 220,
                heightCap: 180,
                pageBackgroundImage: backdrop,
                minimumBackdropExtent: minimumBackdropExtent
            ).chunks.reduce(CGFloat(0)) { $0 + $1.height }
        }

        let natural = totalHeight(minimumBackdropExtent: 0)
        try #require(natural > 844)
        #expect(totalHeight(minimumBackdropExtent: 844) == natural)
    }

    @Test("vertical-rl pads the backdrop chapter along the scroll axis (width)")
    func verticalShortBackdropChapterFillsOneViewport() throws {
        let backdrop = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 48)).image { _ in }
        let attr = NSAttributedString(
            string: "第十四回\n林如海捐馆扬州城\n",
            attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black]
        )

        let unpadded = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 700,
            writingMode: .verticalRTL,
            pageBackgroundImage: backdrop
        )
        let padded = CoreTextChunkSlicer.slice(
            attributedString: attr,
            chapterIndex: 0,
            contentWidth: 700,
            writingMode: .verticalRTL,
            pageBackgroundImage: backdrop,
            minimumBackdropExtent: 390
        )

        let narrow = try #require(unpadded.chunks.first)
        try #require(narrow.width < 390)
        #expect(padded.chunks.count == 1)
        let filled = try #require(padded.chunks.first)
        #expect(filled.width >= 390)
        #expect(filled.charRange.length == narrow.charRange.length)
    }

    @Test("the scroll engine hands its viewport extent to the slicer")
    @MainActor
    func scrollEngineAppliesViewportExtentToBackdropChapter() async throws {
        let engine = CoreTextScrollEngine(
            builder: PageBackdropScrollTestBuilder(color: .darkGray, image: UIGraphicsImageRenderer(
                size: CGSize(width: 12, height: 24)
            ).image { _ in }),
            renderSettings: Self.renderSettings
        )

        await engine.start(initialChapter: 0, contentWidth: 220, viewportExtent: 800)

        let chunk = try #require(engine.chunks.first)
        #expect(chunk.height >= 800)
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
            sideInsets: .init(left: 12, right: 12),
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

    @Test(
        "actual Project Hail Mary EPUB builds IR scroll chunks",
        .enabled(if: fixtureURL(projectHailMaryPath) != nil, "Needs the Project Hail Mary EPUB in Test document/EPUB Format")
    )
    @MainActor
    func actualProjectHailMaryBuildsIRScrollChunks() async throws {
        let sourceURL = try #require(Self.fixtureURL(Self.projectHailMaryPath))
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

    @Test(
        "actual Hated Courage EPUB keeps title in vertical IR scroll chunks",
        .enabled(if: fixtureURL(hatedCouragePath) != nil, "Needs the 被讨厌的勇气 EPUB in Test document/EPUB Format")
    )
    @MainActor
    func actualHatedCourageKeepsTitleInVerticalIRScrollChunks() async throws {
        let sourceURL = try #require(Self.fixtureURL(Self.hatedCouragePath))
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
                // Ends where its next column starts (`ScrollChunkSeamSpacingTests`), which
                // is within a column of the cap.
                #expect(abs(chunk.width - 480) < 18 * 3)
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

    @MainActor
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

    /// Every fourth paragraph a column far shorter than the screen is tall.
    private static let verticalChapterWithShortColumns = (0..<160)
        .map { $0 % 4 == 2 ? "「好。」" : "直排測試文字，應該從右邊開始呈現，並且往左連續前進。" }
        .joined(separator: "\n")

    /// One chunk, but two screens wide: the shape of a short TXT chapter.
    private static let shortVerticalChapter = (0..<10)
        .map { "第\($0)段，直排從右邊開始。" }
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
