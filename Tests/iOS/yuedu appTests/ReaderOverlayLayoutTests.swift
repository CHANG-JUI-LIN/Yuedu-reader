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
                    customText: kind == .customText ? "Fixture" : "",
                    batteryVisual: kind == .battery ? .importedSVG : .system,
                    svgAssetID: kind == .battery ? fixtureUUID(500) : nil,
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

    @Test("configuration decoding supplies evolvable defaults")
    func configurationDecodingSuppliesDefaults() throws {
        let decoded = try JSONDecoder().decode(
            ReaderOverlayComponentConfiguration.self,
            from: Data("{}".utf8)
        )

        #expect(decoded.customText == "")
        #expect(decoded.svgAssetID == nil)
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

    @Test("legacy migration produces deterministic distinct identities")
    func legacyMigrationProducesDeterministicDistinctIdentities() {
        let legacy = migrationFixture()

        let first = ReaderOverlayLayoutMigration.migrate(legacy)
        let second = ReaderOverlayLayoutMigration.migrate(legacy)

        #expect(first == second)
        #expect(Set(first.components.map(\.id)).count == first.components.count)
        #expect(first.components[1].kind == .currentTime)
        #expect(first.components[4].kind == .currentTime)
        #expect(first.components[1].id != first.components[4].id)
    }

    @Test("component factory normalizes new component position")
    func componentFactoryNormalizesPosition() {
        let component = ReaderOverlayComponent.make(
            kind: .customText,
            position: ReaderOverlayNormalizedPoint(x: -10, y: 10)
        )

        #expect(component.position == ReaderOverlayNormalizedPoint(x: 0, y: 1))
    }

    @Test("extreme legacy paddings still produce normalized positions")
    func extremeLegacyPaddingsProduceNormalizedPositions() {
        let fixtures = [
            ReaderLegacyOverlaySettings(
                headerVisible: true,
                footerVisible: true,
                headerFieldPositions: ["chapterTitle": "left", "time": "right"],
                headerTopPadding: -1_000_000,
                headerHorizontalPadding: -1_000_000,
                footerBottomPadding: -1_000_000,
                footerHorizontalPadding: -1_000_000,
                topContentReservation: -1_000_000,
                bottomContentReservation: -1_000_000
            ),
            ReaderLegacyOverlaySettings(
                headerVisible: true,
                footerVisible: true,
                headerFieldPositions: ["chapterTitle": "left", "time": "right"],
                headerTopPadding: 1_000_000,
                headerHorizontalPadding: 1_000_000,
                footerBottomPadding: 1_000_000,
                footerHorizontalPadding: 1_000_000,
                topContentReservation: 1_000_000,
                bottomContentReservation: 1_000_000
            )
        ]

        for fixture in fixtures {
            let layout = ReaderOverlayLayoutMigration.migrate(fixture)
            #expect(layout.components.allSatisfy {
                (0...1).contains($0.position.x) && (0...1).contains($0.position.y)
            })
        }
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
        #expect(first.shouldPersistPrimary)
        #expect(second == first)
    }

    @Test("future stored layout uses deterministic fallback and is not persisted")
    func futureStoredLayoutUsesDeterministicFallback() throws {
        let future = ReaderOverlayLayout(
            version: ReaderOverlayLayout.currentVersion + 1,
            components: [
                ReaderOverlayComponent(
                    id: fixtureUUID(700),
                    kind: .customText,
                    position: ReaderOverlayNormalizedPoint(x: -2, y: 3)
                )
            ],
            contentReservations: ReaderOverlayContentReservations(top: -1, bottom: 999)
        )
        let originalData = try JSONEncoder().encode(future)

        let resolution = ReaderOverlayLayoutMigration.resolve(
            storedData: originalData,
            legacy: migrationFixture()
        )

        #expect(resolution.layout == ReaderOverlayLayoutMigration.migrate(migrationFixture()))
        #expect(resolution.corruptData == nil)
        #expect(!resolution.shouldPersistPrimary)
    }

    @Test("future unknown values preserve primary bytes without corrupt fallback")
    func futureUnknownValuesPreservePrimaryBytes() throws {
        let rawFutureData = Data(
            """
            {
              "version": 999,
              "components": [
                {
                  "id": "00000000-0000-0000-0000-000000000999",
                  "kind": "futureComponentKind",
                  "position": { "x": 0.25, "y": 0.75 },
                  "configuration": { "displayFormat": "futureDisplayFormat" }
                }
              ],
              "contentReservations": { "top": 40, "bottom": 40 }
            }
            """.utf8
        )
        let legacy = migrationFixture()

        let resolution = ReaderOverlayLayoutMigration.resolve(
            storedData: rawFutureData,
            legacy: legacy
        )
        var retainedPrimaryData = rawFutureData
        if resolution.shouldPersistPrimary {
            retainedPrimaryData = try JSONEncoder().encode(resolution.layout)
        }

        #expect(resolution.layout == ReaderOverlayLayoutMigration.migrate(legacy))
        #expect(resolution.corruptData == nil)
        #expect(!resolution.shouldPersistPrimary)
        #expect(retainedPrimaryData == rawFutureData)
    }

    @Test("known old layout upgrades and requests persistence")
    func knownOldLayoutUpgradesAndRequestsPersistence() throws {
        let old = ReaderOverlayLayout(
            version: 0,
            components: [
                ReaderOverlayComponent(
                    id: fixtureUUID(701),
                    kind: .bookTitle,
                    position: ReaderOverlayNormalizedPoint(x: -1, y: 2)
                )
            ],
            contentReservations: ReaderOverlayContentReservations(top: -5, bottom: 500)
        )

        let resolution = ReaderOverlayLayoutMigration.resolve(
            storedData: try JSONEncoder().encode(old),
            legacy: migrationFixture()
        )

        #expect(resolution.shouldPersistPrimary)
        #expect(resolution.layout.version == ReaderOverlayLayout.currentVersion)
        #expect(resolution.layout.components[0].id == fixtureUUID(701))
        #expect(resolution.layout.components[0].position == ReaderOverlayNormalizedPoint(x: 0, y: 1))
        #expect(resolution.layout.contentReservations == ReaderOverlayContentReservations(top: 0, bottom: 120))
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
        #expect(resolution.shouldPersistPrimary)
        #expect(resolution.layout.components.isEmpty)
        #expect(resolution.layout.contentReservations == ReaderOverlayContentReservations(top: 24, bottom: 24))
    }

    @Test("default layout contains stable canonical component identities")
    func defaultLayoutContainsStableCanonicalIdentities() {
        #expect(ReaderOverlayLayout.default == ReaderOverlayLayoutMigration.defaultLayout)
        #expect(ReaderOverlayLayout.default.components.map(\.kind) == [
            .chapterTitle,
            .currentTime,
            .battery,
            .chapterPage,
            .totalProgressText
        ])
        #expect(ReaderOverlayLayout.default.components.map(\.id) == [
            UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        ])
    }

    @Test("persistence normalizes before writing")
    func persistenceNormalizesBeforeWriting() throws {
        let current = ReaderOverlayLayout.default
        let proposed = ReaderOverlayLayout(
            version: 0,
            components: [
                ReaderOverlayComponent(
                    id: fixtureUUID(800),
                    kind: .customText,
                    position: ReaderOverlayNormalizedPoint(x: -4, y: 4),
                    style: ReaderOverlayComponentStyle(fontSize: 1, opacity: 8)
                )
            ],
            contentReservations: ReaderOverlayContentReservations(top: -5, bottom: 500)
        )
        var persistedData: Data?

        let result = ReaderOverlayLayoutPersistence.save(
            current: current,
            proposed: proposed
        ) { data in
            persistedData = data
            return true
        }

        #expect(result.didPersist)
        #expect(result.layout.version == ReaderOverlayLayout.currentVersion)
        #expect(result.layout.components[0].position == ReaderOverlayNormalizedPoint(x: 0, y: 1))
        #expect(result.layout.components[0].style.fontSize == 8)
        #expect(result.layout.components[0].style.opacity == 1)
        #expect(result.layout.contentReservations == ReaderOverlayContentReservations(top: 0, bottom: 120))
        let data = try #require(persistedData)
        #expect(try JSONDecoder().decode(ReaderOverlayLayout.self, from: data) == result.layout)
    }

    @Test("persistence rejects future layouts without writing")
    func persistenceRejectsFutureLayouts() {
        let current = ReaderOverlayLayout.default
        let future = ReaderOverlayLayout(
            version: ReaderOverlayLayout.currentVersion + 1,
            components: [],
            contentReservations: ReaderOverlayContentReservations(top: 0, bottom: 0)
        )
        var didWrite = false

        let result = ReaderOverlayLayoutPersistence.save(
            current: current,
            proposed: future
        ) { _ in
            didWrite = true
            return true
        }

        #expect(!result.didPersist)
        #expect(result.layout == current)
        #expect(!didWrite)
    }

    @Test("persistence failure leaves the in-memory layout unchanged")
    func persistenceFailureLeavesLayoutUnchanged() {
        let current = ReaderOverlayLayout.default
        let proposed = ReaderOverlayLayout(
            components: [
                ReaderOverlayComponent.make(
                    kind: .customText,
                    position: ReaderOverlayNormalizedPoint(x: 0.25, y: 0.75)
                )
            ],
            contentReservations: ReaderOverlayContentReservations(top: 10, bottom: 20)
        )

        let result = ReaderOverlayLayoutPersistence.save(
            current: current,
            proposed: proposed,
            persist: { _ in false }
        )

        #expect(!result.didPersist)
        #expect(result.layout == current)
    }

    private func fixtureUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    }

    private func migrationFixture() -> ReaderLegacyOverlaySettings {
        ReaderLegacyOverlaySettings(
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
    }
}
