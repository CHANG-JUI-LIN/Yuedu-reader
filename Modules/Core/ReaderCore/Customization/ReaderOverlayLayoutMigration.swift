import Foundation

struct ReaderLegacyOverlaySettings: Equatable, Sendable {
    var headerVisible: Bool
    var footerVisible: Bool
    var headerFieldPositions: [String: String]
    var headerTopPadding: Double
    var headerHorizontalPadding: Double
    var footerBottomPadding: Double
    var footerHorizontalPadding: Double
    var topContentReservation: Double
    var bottomContentReservation: Double
}

struct ReaderOverlayLayoutResolution: Equatable, Sendable {
    var layout: ReaderOverlayLayout
    var corruptData: Data?
}

enum ReaderOverlayLayoutMigration {
    private static let canonicalWidth = 390.0
    private static let canonicalHeight = 844.0
    private static let legacyBandHeight = 16.0

    static let defaultLayout = ReaderOverlayLayout(
        version: ReaderOverlayLayout.currentVersion,
        components: [
            .make(kind: .chapterTitle, position: ReaderOverlayNormalizedPoint(x: 0.06, y: 0.04)),
            .make(kind: .currentTime, position: ReaderOverlayNormalizedPoint(x: 0.94, y: 0.04)),
            .make(kind: .battery, position: ReaderOverlayNormalizedPoint(x: 0.06, y: 0.96)),
            .make(kind: .chapterPage, position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.96)),
            .make(kind: .totalProgressText, position: ReaderOverlayNormalizedPoint(x: 0.94, y: 0.96))
        ],
        // Matches the pre-overlay default header/footer reservations:
        // 6 + 16 + 12 at the top, and 16 + 4 + 12 at the bottom.
        contentReservations: ReaderOverlayContentReservations(top: 34, bottom: 32)
    )

    static func resolve(
        storedData: Data?,
        legacy: ReaderLegacyOverlaySettings
    ) -> ReaderOverlayLayoutResolution {
        guard let storedData else {
            return ReaderOverlayLayoutResolution(layout: migrate(legacy), corruptData: nil)
        }

        do {
            let storedLayout = try JSONDecoder().decode(ReaderOverlayLayout.self, from: storedData)
            return ReaderOverlayLayoutResolution(layout: upgrade(storedLayout), corruptData: nil)
        } catch {
            return ReaderOverlayLayoutResolution(
                layout: migrate(legacy),
                corruptData: storedData
            )
        }
    }

    static func migrate(_ legacy: ReaderLegacyOverlaySettings) -> ReaderOverlayLayout {
        var components: [ReaderOverlayComponent] = []

        if legacy.headerVisible {
            components.append(contentsOf: migrateHeader(legacy))
        }
        if legacy.footerVisible {
            components.append(contentsOf: migrateFooter(legacy))
        }

        return upgrade(
            ReaderOverlayLayout(
                version: ReaderOverlayLayout.currentVersion,
                components: components,
                contentReservations: ReaderOverlayContentReservations(
                    top: legacy.topContentReservation,
                    bottom: legacy.bottomContentReservation
                )
            )
        )
    }

    static func upgrade(_ layout: ReaderOverlayLayout) -> ReaderOverlayLayout {
        ReaderOverlayLayout(
            version: ReaderOverlayLayout.currentVersion,
            components: layout.components.map(\.normalized),
            contentReservations: layout.contentReservations.normalized
        )
    }

    private static func migrateHeader(
        _ legacy: ReaderLegacyOverlaySettings
    ) -> [ReaderOverlayComponent] {
        let mappings: [(legacyKey: String, kind: ReaderOverlayComponentKind)] = [
            ("bookTitle", .bookTitle),
            ("chapterTitle", .chapterTitle),
            ("page", .chapterPage),
            ("progress", .totalProgressText),
            ("time", .currentTime),
            ("battery", .battery)
        ]
        let y = (legacy.headerTopPadding + legacyBandHeight / 2) / canonicalHeight

        return mappings.compactMap { mapping in
            guard let rawPosition = legacy.headerFieldPositions[mapping.legacyKey],
                  let position = LegacyHorizontalPosition(rawValue: rawPosition),
                  position != .hidden else {
                return nil
            }

            return ReaderOverlayComponent.make(
                kind: mapping.kind,
                position: ReaderOverlayNormalizedPoint(
                    x: headerX(
                        for: position,
                        horizontalPadding: legacy.headerHorizontalPadding
                    ),
                    y: y
                )
            )
        }
    }

    private static func migrateFooter(
        _ legacy: ReaderLegacyOverlaySettings
    ) -> [ReaderOverlayComponent] {
        let left = legacy.footerHorizontalPadding / canonicalWidth
        let right = (canonicalWidth - legacy.footerHorizontalPadding) / canonicalWidth
        let y = (
            canonicalHeight - legacy.footerBottomPadding - legacyBandHeight / 2
        ) / canonicalHeight

        return [
            .make(
                kind: .chapterPage,
                position: ReaderOverlayNormalizedPoint(x: left, y: y)
            ),
            .make(
                kind: .totalProgressText,
                position: ReaderOverlayNormalizedPoint(x: left + 72 / canonicalWidth, y: y)
            ),
            .make(
                kind: .currentTime,
                position: ReaderOverlayNormalizedPoint(x: right - 48 / canonicalWidth, y: y)
            ),
            .make(
                kind: .battery,
                position: ReaderOverlayNormalizedPoint(x: right, y: y)
            )
        ]
    }

    private static func headerX(
        for position: LegacyHorizontalPosition,
        horizontalPadding: Double
    ) -> Double {
        switch position {
        case .hidden:
            return 0.5
        case .left:
            return horizontalPadding / canonicalWidth
        case .center:
            return 0.5
        case .right:
            return (canonicalWidth - horizontalPadding) / canonicalWidth
        }
    }

    private enum LegacyHorizontalPosition: String {
        case hidden
        case left
        case center
        case right
    }
}
