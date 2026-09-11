import Foundation

struct ReaderBarLayoutResolution: Equatable, Sendable {
    var layout: ReaderBarLayout
    var corruptData: Data?
    var shouldPersistPrimary: Bool
}

struct ReaderBarLayoutPersistenceResult: Equatable, Sendable {
    var layout: ReaderBarLayout
    var didPersist: Bool
}

enum ReaderBarLayoutPersistence {
    static func save(
        current: ReaderBarLayout,
        proposed: ReaderBarLayout,
        persist: (Data) -> Bool
    ) -> ReaderBarLayoutPersistenceResult {
        guard proposed.version <= ReaderBarLayout.currentVersion else {
            return ReaderBarLayoutPersistenceResult(layout: current, didPersist: false)
        }

        let normalized = proposed.normalized(preservingVersion: false)
        guard let data = try? JSONEncoder().encode(normalized), persist(data) else {
            return ReaderBarLayoutPersistenceResult(layout: current, didPersist: false)
        }

        return ReaderBarLayoutPersistenceResult(layout: normalized, didPersist: true)
    }
}

enum ReaderBarLayoutMigration {

    // MARK: - Default

    /// The same visual default the free-position layout shipped — chapter title
    /// top-left; page, progress bottom-left; time, battery bottom-right — restated
    /// as slots. Someone who never customised anything sees no change at all.
    static let defaultLayout = ReaderBarLayout(
        version: ReaderBarLayout.currentVersion,
        fields: [
            ReaderBarField(kind: .chapterTitle, slot: .headerLeft),
            ReaderBarField(kind: .chapterPage, slot: .footerLeft),
            ReaderBarField(kind: .totalProgressText, slot: .footerLeft),
            ReaderBarField(kind: .currentTime, slot: .footerRight),
            ReaderBarField(
                kind: .battery,
                slot: .footerRight,
                configuration: ReaderOverlayComponentConfiguration(showsBatteryPercentage: true)
            ),
            ReaderBarField(kind: .bookTitle, slot: .hidden),
            ReaderBarField(kind: .progressBar, slot: .hidden),
            ReaderBarField(kind: .currentDate, slot: .hidden),
            ReaderBarField(kind: .weekday, slot: .hidden),
            ReaderBarField(kind: .readingDuration, slot: .hidden),
            ReaderBarField(kind: .remainingTime, slot: .hidden),
            ReaderBarField(kind: .customText, slot: .hidden)
        ],
        hidesHeaderOnChapterOpening: true
    )

    // MARK: - Snapping free positions onto slots

    /// Vertical split between the two bars. A component sitting above the middle
    /// of the page belonged to the header band, below it to the footer band.
    private static let barSplit = 0.5
    /// Horizontal thirds. Deliberately not 0.33/0.67 exactly: a component centred
    /// at 0.5 must land in the centre slot even after its own width shifts the
    /// stored anchor slightly, so the centre band is widened a little.
    private static let leftUpperBound = 0.30
    private static let rightLowerBound = 0.70

    /// Converts a free-position layout into slots.
    ///
    /// This runs once per device, on the first launch after the bar model lands,
    /// and again whenever a `.qitheme` pack or an exported preset arrives carrying
    /// free coordinates. It is lossy on purpose: a component parked at an arbitrary
    /// point becomes the nearest of six slots. Nothing else about the field —
    /// its kind, its time format, its battery visual, its imported SVG — changes.
    static func snap(_ layout: ReaderOverlayLayout) -> ReaderBarLayout {
        let body = layout.components
        let opening = layout.chapterOpeningComponents

        var fields: [ReaderBarField] = []
        var seen = Set<ReaderOverlayComponentKind>()

        // Sorted so that two components sharing a slot render left-to-right,
        // top-to-bottom — the order they appeared in on the page.
        let sorted = body.sorted { lhs, rhs in
            if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
            return lhs.position.x < rhs.position.x
        }

        let style = sharedStyle(from: sorted)
        for component in sorted where !seen.contains(component.kind) {
            seen.insert(component.kind)
            fields.append(
                ReaderBarField(
                    kind: component.kind,
                    slot: slot(for: component.position),
                    configuration: component.configuration,
                    color: component.style.color == style.color
                        ? nil : component.style.color
                )
            )
        }

        for kind in ReaderOverlayComponentKind.allCases where !seen.contains(kind) {
            fields.append(ReaderBarField(kind: kind, slot: .hidden))
        }

        return ReaderBarLayout(
            version: ReaderBarLayout.currentVersion,
            fields: fields,
            hidesHeaderOnChapterOpening: hidesHeaderOnChapterOpening(body: body, opening: opening),
            style: style,
            edgeDistances: layout.barEdgeDistances ?? ReaderBarEdgeDistances()
        ).normalized(preservingVersion: false)
    }

    static func slot(for position: ReaderOverlayNormalizedPoint) -> ReaderBarSlot {
        let bar: ReaderBar = position.y < barSplit ? .header : .footer
        let slots = ReaderBarSlot.slots(in: bar)
        if position.x < leftUpperBound { return slots[0] }
        if position.x >= rightLowerBound { return slots[2] }
        return slots[1]
    }

    /// The two free-position scopes collapse into one bar layout plus this flag.
    ///
    /// A layout whose chapter-opening scope carried no header-band component while
    /// the body scope did was expressing exactly "no header on the chapter's first
    /// page", which is what the flag now says. Anything else keeps the header on
    /// both, because the bar model cannot express two different header layouts and
    /// silently dropping fields would be worse than showing them twice.
    private static func hidesHeaderOnChapterOpening(
        body: [ReaderOverlayComponent],
        opening: [ReaderOverlayComponent]
    ) -> Bool {
        let bodyHasHeader = body.contains { $0.position.y < barSplit }
        let openingHasHeader = opening.contains { $0.position.y < barSplit }
        return bodyHasHeader && !openingHasHeader
    }

    /// The first component supplies shared typography and the default color.
    /// Other components retain any different color as an individual override.
    private static func sharedStyle(from sorted: [ReaderOverlayComponent]) -> ReaderBarStyle {
        guard let first = sorted.first else { return ReaderBarStyle() }
        return ReaderBarStyle(
            fontSize: first.style.fontSize,
            weight: first.style.fontWeight,
            color: first.style.color,
            opacity: first.style.opacity
        ).normalized
    }

    // MARK: - Back out to free positions

    /// Canonical anchor for each slot — the point `slot(for:)` maps back to the
    /// same slot from, so `snap(freePositionLayout(from: x)) == x`.
    private static func anchor(for slot: ReaderBarSlot) -> ReaderOverlayNormalizedPoint {
        let y: Double
        switch slot.bar {
        case .header: y = 0.08
        case .footer, nil: y = 0.95
        }
        let x: Double
        switch slot {
        case .headerLeft, .footerLeft: x = 0.06
        case .headerCenter, .footerCenter: x = 0.50
        case .headerRight, .footerRight: x = 0.94
        case .hidden: x = 0.50
        }
        return ReaderOverlayNormalizedPoint(x: x, y: y)
    }

    /// Renders the bar layout back into the free-position shape the exported
    /// `readConfig.json` carries.
    ///
    /// The export schema is deliberately legado-compatible — `readerOverlayLayout`
    /// rides along as an extra key legado ignores — so it stays as it is, and this
    /// converts on the way out instead. Without it an export would ship whatever
    /// free-position layout the device last stored, which no longer reflects what
    /// the reader actually draws.
    static func freePositionLayout(from layout: ReaderBarLayout) -> ReaderOverlayLayout {
        let placed = layout.normalized().fields.filter { $0.slot != .hidden }
        let components = placed.map { field in
            ReaderOverlayComponent(
                id: UUID(),
                kind: field.kind,
                position: anchor(for: field.slot),
                style: ReaderOverlayComponentStyle(
                    fontSize: layout.style.fontSize,
                    fontWeight: layout.style.weight,
                    color: field.color ?? layout.style.color,
                    opacity: layout.style.opacity
                ),
                configuration: field.configuration
            )
        }
        let opening = layout.hidesHeaderOnChapterOpening
            ? components.filter { $0.position.y >= barSplit }
            : components
        return ReaderOverlayLayout(
            components: components,
            chapterOpeningComponents: opening,
            contentReservations: ReaderOverlayContentReservations(top: 90, bottom: 32),
            barEdgeDistances: layout.edgeDistances
        )
    }

    // MARK: - Loading

    /// Resolves the stored bar layout, falling back to the free-position layout
    /// that preceded it.
    ///
    /// - Parameters:
    ///   - storedData: JSON written by a previous run of the bar model, if any.
    ///   - legacyLayout: the already-resolved free-position layout. Passing the
    ///     resolved value rather than its JSON matters: on a device that never
    ///     stored one, `ReaderOverlayLayoutMigration` synthesises it from the
    ///     even older loose `yd_reader_header_*` defaults, and decoding raw data
    ///     here would miss exactly those users and reset them to the stock bars.
    static func resolve(
        storedData: Data?,
        legacyLayout: ReaderOverlayLayout?
    ) -> ReaderBarLayoutResolution {
        let decoder = JSONDecoder()

        if let storedData {
            do {
                let stored = try decoder.decode(ReaderBarLayout.self, from: storedData)
                guard stored.version <= ReaderBarLayout.currentVersion else {
                    // Written by a newer build on another device. Show the default
                    // rather than a half-understood layout, and keep the bytes so the
                    // newer build can still read them.
                    return ReaderBarLayoutResolution(
                        layout: defaultLayout,
                        corruptData: nil,
                        shouldPersistPrimary: false
                    )
                }
                return ReaderBarLayoutResolution(
                    layout: stored.normalized(),
                    corruptData: nil,
                    shouldPersistPrimary: false
                )
            } catch {
                // Keep the unreadable bytes for diagnosis instead of dropping them,
                // then fall through to the legacy layout.
                return ReaderBarLayoutResolution(
                    layout: migrateLegacy(legacyLayout),
                    corruptData: storedData,
                    shouldPersistPrimary: true
                )
            }
        }

        return ReaderBarLayoutResolution(
            layout: migrateLegacy(legacyLayout),
            corruptData: nil,
            shouldPersistPrimary: true
        )
    }

    private static func migrateLegacy(_ legacyLayout: ReaderOverlayLayout?) -> ReaderBarLayout {
        guard let legacyLayout else { return defaultLayout }
        return snap(legacyLayout)
    }
}
