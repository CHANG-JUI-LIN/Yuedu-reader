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
    var shouldPersistPrimary: Bool
}

struct ReaderOverlayLayoutPersistenceResult: Equatable, Sendable {
    var layout: ReaderOverlayLayout
    var didPersist: Bool
}

enum ReaderOverlayLayoutPersistence {
    static func save(
        current: ReaderOverlayLayout,
        proposed: ReaderOverlayLayout,
        persist: (Data) -> Bool
    ) -> ReaderOverlayLayoutPersistenceResult {
        guard proposed.version <= ReaderOverlayLayout.currentVersion else {
            return ReaderOverlayLayoutPersistenceResult(layout: current, didPersist: false)
        }

        let normalized = proposed.normalized(preservingVersion: false)
        guard let data = try? JSONEncoder().encode(normalized), persist(data) else {
            return ReaderOverlayLayoutPersistenceResult(layout: current, didPersist: false)
        }

        return ReaderOverlayLayoutPersistenceResult(layout: normalized, didPersist: true)
    }
}

enum ReaderOverlayLayoutMigration {
    private static let canonicalWidth = 390.0
    private static let canonicalHeight = 844.0
    private static let legacyBandHeight = 16.0

    static let defaultLayout = ReaderOverlayLayout(
        version: ReaderOverlayLayout.currentVersion,
        components: [
            ReaderOverlayComponent(
                id: ComponentID.defaultChapterTitle,
                kind: .chapterTitle,
                position: ReaderOverlayNormalizedPoint(x: 0.06, y: 0.04)
            ),
            ReaderOverlayComponent(
                id: ComponentID.defaultCurrentTime,
                kind: .currentTime,
                position: ReaderOverlayNormalizedPoint(x: 0.94, y: 0.04)
            ),
            ReaderOverlayComponent(
                id: ComponentID.defaultBattery,
                kind: .battery,
                position: ReaderOverlayNormalizedPoint(x: 0.06, y: 0.96)
            ),
            ReaderOverlayComponent(
                id: ComponentID.defaultChapterPage,
                kind: .chapterPage,
                position: ReaderOverlayNormalizedPoint(x: 0.5, y: 0.96)
            ),
            ReaderOverlayComponent(
                id: ComponentID.defaultTotalProgress,
                kind: .totalProgressText,
                position: ReaderOverlayNormalizedPoint(x: 0.94, y: 0.96)
            )
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
            return ReaderOverlayLayoutResolution(
                layout: migrate(legacy),
                corruptData: nil,
                shouldPersistPrimary: true
            )
        }

        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(LayoutVersionEnvelope.self, from: storedData),
           envelope.version > ReaderOverlayLayout.currentVersion {
            return ReaderOverlayLayoutResolution(
                layout: migrate(legacy),
                corruptData: nil,
                shouldPersistPrimary: false
            )
        }

        do {
            let storedLayout = try decoder.decode(ReaderOverlayLayout.self, from: storedData)
            guard storedLayout.version <= ReaderOverlayLayout.currentVersion else {
                return ReaderOverlayLayoutResolution(
                    layout: migrate(legacy),
                    corruptData: nil,
                    shouldPersistPrimary: false
                )
            }
            return ReaderOverlayLayoutResolution(
                layout: upgrade(storedLayout),
                corruptData: nil,
                shouldPersistPrimary: true
            )
        } catch {
            return ReaderOverlayLayoutResolution(
                layout: migrate(legacy),
                corruptData: storedData,
                shouldPersistPrimary: true
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
        guard layout.version <= ReaderOverlayLayout.currentVersion else { return layout }
        return layout.normalized(preservingVersion: false)
    }

    private static func migrateHeader(
        _ legacy: ReaderLegacyOverlaySettings
    ) -> [ReaderOverlayComponent] {
        let mappings: [(legacyKey: String, kind: ReaderOverlayComponentKind, id: UUID)] = [
            ("bookTitle", .bookTitle, ComponentID.legacyHeaderBookTitle),
            ("chapterTitle", .chapterTitle, ComponentID.legacyHeaderChapterTitle),
            ("page", .chapterPage, ComponentID.legacyHeaderChapterPage),
            ("progress", .totalProgressText, ComponentID.legacyHeaderTotalProgress),
            ("time", .currentTime, ComponentID.legacyHeaderCurrentTime),
            ("battery", .battery, ComponentID.legacyHeaderBattery)
        ]
        let y = (legacy.headerTopPadding + legacyBandHeight / 2) / canonicalHeight

        return mappings.compactMap { mapping in
            guard let rawPosition = legacy.headerFieldPositions[mapping.legacyKey],
                  let position = LegacyHorizontalPosition(rawValue: rawPosition),
                  position != .hidden else {
                return nil
            }

            return ReaderOverlayComponent(
                id: mapping.id,
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
            ReaderOverlayComponent(
                id: ComponentID.legacyFooterChapterPage,
                kind: .chapterPage,
                position: ReaderOverlayNormalizedPoint(x: left, y: y)
            ),
            ReaderOverlayComponent(
                id: ComponentID.legacyFooterTotalProgress,
                kind: .totalProgressText,
                position: ReaderOverlayNormalizedPoint(x: left + 72 / canonicalWidth, y: y)
            ),
            ReaderOverlayComponent(
                id: ComponentID.legacyFooterCurrentTime,
                kind: .currentTime,
                position: ReaderOverlayNormalizedPoint(x: right - 48 / canonicalWidth, y: y)
            ),
            ReaderOverlayComponent(
                id: ComponentID.legacyFooterBattery,
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

    private struct LayoutVersionEnvelope: Decodable {
        var version: Int

        private enum CodingKeys: String, CodingKey {
            case version
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        }
    }

    private enum ComponentID {
        static let defaultChapterTitle = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        static let defaultCurrentTime = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        static let defaultBattery = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        static let defaultChapterPage = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        static let defaultTotalProgress = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!

        static let legacyHeaderBookTitle = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        static let legacyHeaderChapterTitle = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        static let legacyHeaderChapterPage = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        static let legacyHeaderTotalProgress = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        static let legacyHeaderCurrentTime = UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        static let legacyHeaderBattery = UUID(uuidString: "00000000-0000-0000-0000-000000000206")!

        static let legacyFooterChapterPage = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        static let legacyFooterTotalProgress = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        static let legacyFooterCurrentTime = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
        static let legacyFooterBattery = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
    }
}
