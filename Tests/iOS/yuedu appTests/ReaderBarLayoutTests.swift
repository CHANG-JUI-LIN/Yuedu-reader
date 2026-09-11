import CoreFoundation
import Foundation
import Testing
@testable import yuedu_app

struct ReaderBarLayoutTests {

    // MARK: - Helpers

    private func component(
        _ kind: ReaderOverlayComponentKind,
        x: Double,
        y: Double,
        configuration: ReaderOverlayComponentConfiguration = ReaderOverlayComponentConfiguration()
    ) -> ReaderOverlayComponent {
        ReaderOverlayComponent(
            id: UUID(),
            kind: kind,
            position: ReaderOverlayNormalizedPoint(x: x, y: y),
            style: ReaderOverlayComponentStyle(),
            configuration: configuration
        )
    }

    private func layout(
        body: [ReaderOverlayComponent],
        opening: [ReaderOverlayComponent]? = nil
    ) -> ReaderOverlayLayout {
        ReaderOverlayLayout(
            components: body,
            chapterOpeningComponents: opening ?? body,
            contentReservations: ReaderOverlayContentReservations(top: 90, bottom: 32)
        )
    }

    // MARK: - Snapping

    @Test("Top half snaps to the header, bottom half to the footer")
    func verticalSplit() {
        let snapped = ReaderBarLayoutMigration.snap(
            layout(body: [
                component(.bookTitle, x: 0.05, y: 0.07),
                component(.chapterPage, x: 0.05, y: 0.96)
            ])
        )

        #expect(snapped.slot(for: .bookTitle) == .headerLeft)
        #expect(snapped.slot(for: .chapterPage) == .footerLeft)
    }

    @Test("Horizontal thirds pick left, centre and right")
    func horizontalThirds() {
        let snapped = ReaderBarLayoutMigration.snap(
            layout(body: [
                component(.bookTitle, x: 0.05, y: 0.08),
                component(.chapterTitle, x: 0.50, y: 0.08),
                component(.currentTime, x: 0.94, y: 0.08)
            ])
        )

        #expect(snapped.slot(for: .bookTitle) == .headerLeft)
        #expect(snapped.slot(for: .chapterTitle) == .headerCenter)
        #expect(snapped.slot(for: .currentTime) == .headerRight)
    }

    /// A component parked dead centre must land in the centre slot. The bands are
    /// not exact thirds for this reason — a centred component's stored anchor
    /// drifts a little with its own width.
    @Test("A centred component lands in the centre slot")
    func centreStaysCentred() {
        let snapped = ReaderBarLayoutMigration.snap(
            layout(body: [component(.chapterTitle, x: 0.5, y: 0.9)])
        )

        #expect(snapped.slot(for: .chapterTitle) == .footerCenter)
    }

    @Test("Per-field configuration survives the snap")
    func configurationSurvives() {
        let snapped = ReaderBarLayoutMigration.snap(
            layout(body: [
                component(
                    .battery,
                    x: 0.94,
                    y: 0.96,
                    configuration: ReaderOverlayComponentConfiguration(
                        displayFormat: .percentage,
                        batteryVisual: .system,
                        showsBatteryPercentage: true
                    )
                )
            ])
        )

        let battery = snapped.fields.first { $0.kind == .battery }
        #expect(battery?.slot == .footerRight)
        #expect(battery?.configuration.showsBatteryPercentage == true)
        #expect(battery?.configuration.displayFormat == .percentage)
    }

    @Test("Every kind gets exactly one entry, unplaced ones hidden")
    func everyKindPresentOnce() {
        let snapped = ReaderBarLayoutMigration.snap(
            layout(body: [component(.chapterTitle, x: 0.05, y: 0.08)])
        )

        #expect(snapped.fields.count == ReaderOverlayComponentKind.allCases.count)
        for kind in ReaderOverlayComponentKind.allCases {
            #expect(snapped.fields.filter { $0.kind == kind }.count == 1)
        }
        #expect(snapped.slot(for: .customText) == .hidden)
    }

    /// Two scopes collapse into one layout plus a flag. A body scope with a header
    /// and an opening scope without one was saying "no header on the first page".
    @Test("Opening scope without a header becomes the hide-on-opening flag")
    func openingScopeBecomesFlag() {
        let snapped = ReaderBarLayoutMigration.snap(
            layout(
                body: [
                    component(.chapterTitle, x: 0.05, y: 0.08),
                    component(.chapterPage, x: 0.05, y: 0.96)
                ],
                opening: [component(.chapterPage, x: 0.05, y: 0.96)]
            )
        )

        #expect(snapped.hidesHeaderOnChapterOpening)
    }

    @Test("A header on both scopes keeps the header on chapter openings")
    func headerOnBothScopesKeepsHeader() {
        let both = [
            component(.chapterTitle, x: 0.05, y: 0.08),
            component(.chapterPage, x: 0.05, y: 0.96)
        ]
        let snapped = ReaderBarLayoutMigration.snap(layout(body: both, opening: both))

        #expect(!snapped.hidesHeaderOnChapterOpening)
    }

    @Test("The stock free-position layout snaps to the stock bar layout")
    func defaultLayoutRoundTrips() {
        let snapped = ReaderBarLayoutMigration.snap(.default)

        #expect(snapped.slot(for: .chapterTitle) == .headerLeft)
        #expect(snapped.slot(for: .chapterPage) == .footerLeft)
        #expect(snapped.slot(for: .totalProgressText) == .footerLeft)
        #expect(snapped.slot(for: .currentTime) == .footerRight)
        #expect(snapped.slot(for: .battery) == .footerRight)
    }

    // MARK: - Model

    @Test("An empty bar reports no content so nothing is reserved for it")
    func emptyBarHasNoContent() {
        var layout = ReaderBarLayout.default
        #expect(layout.hasContent(in: .header))

        layout.setSlot(.hidden, for: .chapterTitle)
        #expect(!layout.hasContent(in: .header))
        #expect(layout.hasContent(in: .footer))
    }

    @Test("Fields in one slot keep their stored order")
    func slotOrderIsStable() {
        let footerLeft = ReaderBarLayout.default.fields(in: .footerLeft).map(\.kind)

        #expect(footerLeft == [.chapterPage, .totalProgressText])
    }

    @Test("Normalizing collapses duplicates and fills in missing kinds")
    func normalizationIsTotal() {
        let messy = ReaderBarLayout(
            fields: [
                ReaderBarField(kind: .battery, slot: .footerRight),
                ReaderBarField(kind: .battery, slot: .headerLeft)
            ]
        )
        let clean = messy.normalized()

        #expect(clean.fields.count == ReaderOverlayComponentKind.allCases.count)
        #expect(clean.slot(for: .battery) == .footerRight)
    }

    @Test("Style values are clamped to their ranges")
    func styleClamping() {
        let style = ReaderBarStyle(fontSize: 999, opacity: -5).normalized

        #expect(style.fontSize == ReaderBarStyle.fontSizeRange.upperBound)
        #expect(style.opacity == ReaderBarStyle.opacityRange.lowerBound)
    }

    // MARK: - Persistence

    @Test("Individual component colors survive persistence, moving and preset export")
    func componentColorsRoundTrip() throws {
        var layout = ReaderBarLayout.default
        let titleColor = ReaderOverlayColorReference(source: .custom, hexRGBA: 0xFF0000FF, darkHexRGBA: 0xFF8888FF)
        let timeColor = ReaderOverlayColorReference(source: .custom, hexRGBA: 0x008800FF, darkHexRGBA: 0x88FF88FF)
        layout.setColor(titleColor, for: .chapterTitle)
        layout.setColor(timeColor, for: .currentTime)
        layout.setSlot(.footerLeft, for: .chapterTitle)
        let stored = try JSONEncoder().encode(layout.normalized())
        let restored = ReaderBarLayoutMigration.resolve(storedData: stored, legacyLayout: nil).layout
        #expect(restored.fields.first { $0.kind == .chapterTitle }?.color == titleColor)
        #expect(restored.fields.first { $0.kind == .currentTime }?.color == timeColor)
        #expect(restored.fields.first { $0.kind == .battery }?.color == nil)
        let imported = ReaderBarLayoutMigration.snap(ReaderBarLayoutMigration.freePositionLayout(from: restored))
        for kind in [ReaderOverlayComponentKind.chapterTitle, .currentTime, .battery] {
            let before = restored.fields.first { $0.kind == kind }?.color ?? restored.style.color
            let after = imported.fields.first { $0.kind == kind }?.color ?? imported.style.color
            #expect(before == after)
        }
        layout.setColor(nil, for: .chapterTitle)
        #expect(layout.fields.first { $0.kind == .chapterTitle }?.color == nil)
        #expect(layout.fields.first { $0.kind == .currentTime }?.color == timeColor)
    }

    @Test("Existing fields without a color inherit the shared style")
    func oldFieldInheritsColor() throws {
        let field = try JSONDecoder().decode(ReaderBarField.self, from: Data(
            #"{"kind":"chapterTitle","slot":"headerLeft"}"#.utf8
        ))
        #expect(field.color == nil)
    }

    @Test("Light and dark bar colors survive saving and legacy preset export")
    func appearanceColorsRoundTrip() throws {
        var original = ReaderBarLayout.default
        original.style.color = ReaderOverlayColorReference(
            source: .custom, hexRGBA: 0x123456FF, darkHexRGBA: 0xABCDEF80
        )
        var stored = Data()
        let result = ReaderBarLayoutPersistence.save(current: .default, proposed: original) {
            stored = $0
            return true
        }
        #expect(result.didPersist)
        let restored = ReaderBarLayoutMigration.resolve(storedData: stored, legacyLayout: nil).layout
        #expect(restored.style.color == original.style.color)
        let exported = ReaderBarLayoutMigration.freePositionLayout(from: restored)
        let reimported = try JSONDecoder().decode(
            ReaderOverlayLayout.self, from: JSONEncoder().encode(exported)
        )
        #expect(ReaderBarLayoutMigration.snap(reimported).style.color == original.style.color)
    }

    @Test("Old single-color settings remain readable without a dark override")
    func oldColorDecodes() throws {
        let data = Data(#"{"source":"custom","hexRGBA":305420031}"#.utf8)
        let color = try JSONDecoder().decode(ReaderOverlayColorReference.self, from: data)
        #expect(color.hexRGBA == 0x123456FF)
        #expect(color.darkHexRGBA == nil)
    }

    @Test("A stored layout round-trips through JSON")
    func codableRoundTrip() throws {
        var original = ReaderBarLayout.default
        original.setSlot(.headerRight, for: .currentTime)
        original.showsFooterDivider = true

        let data = try JSONEncoder().encode(original.normalized(preservingVersion: false))
        let decoded = try JSONDecoder().decode(ReaderBarLayout.self, from: data)

        #expect(decoded.slot(for: .currentTime) == .headerRight)
        #expect(decoded.showsFooterDivider)
    }

    @Test("A missing stored layout migrates from the free-position one")
    func resolveFallsBackToLegacy() {
        let resolution = ReaderBarLayoutMigration.resolve(
            storedData: nil,
            legacyLayout: .default
        )

        #expect(resolution.shouldPersistPrimary)
        #expect(resolution.corruptData == nil)
        #expect(resolution.layout.slot(for: .chapterTitle) == .headerLeft)
    }

    /// Unreadable bytes are kept rather than dropped, so a decoding regression can
    /// still be diagnosed from a device after the fact.
    @Test("Corrupt stored data is preserved and the legacy layout is used")
    func resolveKeepsCorruptData() {
        let garbage = Data("not json".utf8)
        let resolution = ReaderBarLayoutMigration.resolve(
            storedData: garbage,
            legacyLayout: .default
        )

        #expect(resolution.corruptData == garbage)
        #expect(resolution.shouldPersistPrimary)
        #expect(resolution.layout.slot(for: .chapterTitle) == .headerLeft)
    }

    @Test("A layout from a newer build is not overwritten")
    func newerVersionIsLeftAlone() throws {
        var future = ReaderBarLayout.default
        future.version = ReaderBarLayout.currentVersion + 1
        let data = try JSONEncoder().encode(future)

        let resolution = ReaderBarLayoutMigration.resolve(storedData: data, legacyLayout: nil)

        #expect(!resolution.shouldPersistPrimary)
        #expect(resolution.corruptData == nil)
    }

    // MARK: - Insets

    @Test("Each shown bar adds its own band to the text inset")
    func insetsGrowWithBars() {
        let none = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59,
            safeBottom: 34,
            showsHeader: false,
            showsFooter: false,
            verticalMargin: 12
        )
        let both = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59,
            safeBottom: 34,
            showsHeader: true,
            showsFooter: true,
            verticalMargin: 12
        )

        #expect(both.top > none.top)
        #expect(both.bottom > none.bottom)
    }

    /// The bar's own height plus the reader's 上下邊距 is exactly what the inset adds
    /// on top of where the bar starts. If the renderer and the paginator ever
    /// disagree here, the text runs under a bar or leaves a blank strip.
    @Test("A bar sits exactly inside the band reserved for it")
    func barOffsetMatchesReservedBand() {
        let margin: CGFloat = 12
        let insets = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59,
            safeBottom: 34,
            showsHeader: true,
            showsFooter: true,
            verticalMargin: margin
        )

        #expect(
            insets.top == ReaderLayoutMetrics.headerBarTopOffset(safeTop: 59)
                + ReaderLayoutMetrics.headerHeight + margin
        )
        #expect(
            insets.bottom == ReaderLayoutMetrics.footerBarBottomOffset(safeBottom: 34)
                + ReaderLayoutMetrics.footerHeight + margin
        )
    }

    /// 上下邊距 has to mean the same thing whether or not a bar is showing, and in
    /// either reading mode. It used to mean two different things.
    @Test("The vertical margin moves the text by the same amount either way")
    func verticalMarginIsUniform() {
        func top(showsHeader: Bool, margin: CGFloat) -> CGFloat {
            ReaderLayoutMetrics.barContentInsets(
                safeTop: 59,
                safeBottom: 34,
                showsHeader: showsHeader,
                showsFooter: true,
                verticalMargin: margin
            ).top
        }

        #expect(top(showsHeader: true, margin: 20) - top(showsHeader: true, margin: 10) == 10)
        #expect(top(showsHeader: false, margin: 20) - top(showsHeader: false, margin: 10) == 10)
    }
}
