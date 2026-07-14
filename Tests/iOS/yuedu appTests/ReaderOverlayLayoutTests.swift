import Foundation
import Testing
@testable import yuedu_app

@Suite("Reader overlay layout")
struct ReaderOverlayLayoutTests {
    @Test("every component kind survives a Codable round trip")
    func everyComponentKindCodableRoundTrip() throws {
        let components = ReaderOverlayComponentKind.allCases.enumerated().map { index, kind in
            ReaderOverlayComponent(
                id: fixtureUUID(index),
                kind: kind,
                position: ReaderOverlayNormalizedPoint(
                    x: Double(index) / Double(ReaderOverlayComponentKind.allCases.count),
                    y: 0.25
                ),
                style: ReaderOverlayComponentStyle(
                    font: ReaderOverlayFontReference(
                        kind: .imported,
                        postScriptName: "FixtureFont-\(index)"
                    ),
                    fontSize: 16,
                    fontWeight: .semibold,
                    color: ReaderOverlayColorReference(
                        source: .custom,
                        hexRGBA: 0x12345678
                    ),
                    opacity: 0.85
                ),
                configuration: ReaderOverlayComponentConfiguration(
                    displayFormat: ReaderOverlayDisplayFormat.allCases[
                        index % ReaderOverlayDisplayFormat.allCases.count
                    ],
                    customText: kind == .customText ? "Fixture" : nil,
                    batteryVisual: kind == .battery ? .importedSVG : .system,
                    svgAssetID: kind == .battery ? "fixture-battery" : nil,
                    showsBatteryPercentage: index.isMultiple(of: 2)
                )
            )
        }
        let fixture = ReaderOverlayLayout(
            version: ReaderOverlayLayout.currentVersion,
            components: components,
            contentReservations: ReaderOverlayContentReservations(top: 34, bottom: 32)
        )

        let data = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(ReaderOverlayLayout.self, from: data)

        #expect(decoded == fixture)
    }

    @Test("normalized points clamp both axes")
    func normalizedPointClampsBothAxes() {
        let point = ReaderOverlayNormalizedPoint(x: -0.5, y: 1.8).clamped

        #expect(point == ReaderOverlayNormalizedPoint(x: 0, y: 1))
    }

    @Test("legacy header and footer migrate in stable order")
    func legacyHeaderAndFooterMigration() {
        let legacy = ReaderLegacyOverlaySettings(
            headerVisible: true,
            footerVisible: true,
            headerFieldPositions: [
                "chapterTitle": "left",
                "time": "right",
                "bookTitle": "hidden"
            ],
            headerTopPadding: 10,
            headerHorizontalPadding: 20,
            footerBottomPadding: 8,
            footerHorizontalPadding: 24,
            topContentReservation: 46,
            bottomContentReservation: 36
        )

        let layout = ReaderOverlayLayoutMigration.migrate(legacy)

        #expect(layout.components.map(\.kind) == [
            .chapterTitle,
            .currentTime,
            .chapterPage,
            .totalProgressText,
            .currentTime,
            .battery
        ])
        #expect(layout.contentReservations == ReaderOverlayContentReservations(top: 46, bottom: 36))
        #expect(layout.components.allSatisfy { (0...1).contains($0.position.x) })
        #expect(layout.components.allSatisfy { (0...1).contains($0.position.y) })
    }

    @Test("a stored overlay wins and resolving it is idempotent")
    func storedOverlayWinsAndResolutionIsIdempotent() throws {
        let stored = ReaderOverlayLayout(
            version: ReaderOverlayLayout.currentVersion,
            components: [
                ReaderOverlayComponent.make(
                    kind: .customText,
                    position: ReaderOverlayNormalizedPoint(x: 0.37, y: 0.63)
                )
            ],
            contentReservations: ReaderOverlayContentReservations(top: 12, bottom: 18)
        )
        let noisyLegacy = ReaderLegacyOverlaySettings(
            headerVisible: true,
            footerVisible: true,
            headerFieldPositions: ["bookTitle": "center"],
            headerTopPadding: 30,
            headerHorizontalPadding: 30,
            footerBottomPadding: 30,
            footerHorizontalPadding: 30,
            topContentReservation: 80,
            bottomContentReservation: 80
        )

        let first = ReaderOverlayLayoutMigration.resolve(
            storedData: try JSONEncoder().encode(stored),
            legacy: noisyLegacy
        )
        let second = ReaderOverlayLayoutMigration.resolve(
            storedData: try JSONEncoder().encode(first.layout),
            legacy: noisyLegacy
        )

        #expect(first.layout == stored)
        #expect(first.corruptData == nil)
        #expect(second == first)
    }

    @Test("component style and reservations normalize into supported ranges")
    func styleAndReservationNormalization() {
        let component = ReaderOverlayComponent(
            id: fixtureUUID(100),
            kind: .bookTitle,
            position: ReaderOverlayNormalizedPoint(x: -3, y: 5),
            style: ReaderOverlayComponentStyle(
                font: ReaderOverlayFontReference(kind: .system, postScriptName: "MustBeCleared"),
                fontSize: 2,
                fontWeight: .bold,
                color: ReaderOverlayColorReference(source: .readerText, hexRGBA: 0xFFFFFFFF),
                opacity: 4
            ),
            configuration: ReaderOverlayComponentConfiguration()
        )
        let layout = ReaderOverlayLayout(
            version: 0,
            components: [component],
            contentReservations: ReaderOverlayContentReservations(top: -8, bottom: 200)
        )

        let normalized = ReaderOverlayLayoutMigration.upgrade(layout)

        #expect(normalized.version == ReaderOverlayLayout.currentVersion)
        #expect(normalized.components[0].position == ReaderOverlayNormalizedPoint(x: 0, y: 1))
        #expect(normalized.components[0].style.font.postScriptName == nil)
        #expect(normalized.components[0].style.fontSize == 8)
        #expect(normalized.components[0].style.color.hexRGBA == nil)
        #expect(normalized.components[0].style.opacity == 1)
        #expect(normalized.contentReservations == ReaderOverlayContentReservations(top: 0, bottom: 120))
    }

    @Test("malformed stored data falls back and preserves exact corrupt bytes")
    func malformedDataFallsBackAndPreservesBytes() {
        let malformed = Data([0x00, 0xFF, 0x7B, 0x01])
        let legacy = ReaderLegacyOverlaySettings(
            headerVisible: false,
            footerVisible: false,
            headerFieldPositions: [:],
            headerTopPadding: 6,
            headerHorizontalPadding: 16,
            footerBottomPadding: 4,
            footerHorizontalPadding: 16,
            topContentReservation: 24,
            bottomContentReservation: 24
        )

        let resolution = ReaderOverlayLayoutMigration.resolve(
            storedData: malformed,
            legacy: legacy
        )

        #expect(resolution.corruptData == malformed)
        #expect(resolution.layout.components.isEmpty)
        #expect(resolution.layout.contentReservations == ReaderOverlayContentReservations(top: 24, bottom: 24))
    }

    @Test("default layout contains the canonical five components")
    func defaultLayoutContainsCanonicalComponents() {
        #expect(ReaderOverlayLayout.default == ReaderOverlayLayoutMigration.defaultLayout)
        #expect(ReaderOverlayLayout.default.components.map(\.kind) == [
            .chapterTitle,
            .currentTime,
            .battery,
            .chapterPage,
            .totalProgressText
        ])
    }

    private func fixtureUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    }
}
