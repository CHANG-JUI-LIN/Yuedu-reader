import Foundation
import Testing
@testable import yuedu_app

struct ReaderBarEdgeDistanceTests {
    @Test("Old settings retain both bar positions and body insets")
    func existingGeometryIsUnchanged() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ReaderBarLayout.default)) as? [String: Any])
        object.removeValue(forKey: "edgeDistances")
        let old = try JSONDecoder().decode(ReaderBarLayout.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.edgeDistances == ReaderBarEdgeDistances())
        for (top, bottom) in [(0.0, 0.0), (59.0, 34.0), (62.0, 34.0), (0.0, 21.0)] {
            for header in [false, true] {
                for footer in [false, true] {
                    let insets = ReaderLayoutMetrics.barContentInsets(
                        safeTop: top, safeBottom: bottom, showsHeader: header, showsFooter: footer,
                        verticalMargin: 12, headerTopPadding: 6, footerBottomPadding: 4,
                        headerExtent: 18, footerExtent: 18, edgeDistances: old.edgeDistances
                    )
                    let expectedTop: CGFloat = header ? CGFloat(top) + 6 + 18 + 12 : max(24, CGFloat(top) + 12)
                    let expectedBottom: CGFloat = footer ? CGFloat(bottom) + 4 + 18 + 12 : max(24, CGFloat(bottom) + 12)
                    #expect(insets.top == expectedTop)
                    #expect(insets.bottom == expectedBottom)
                }
            }
        }
    }

    @Test("Zero reaches the screen edge on devices with different safe areas")
    func zeroHasNoSafeAreaFloor() {
        for safeArea in [0.0, 21.0, 34.0, 59.0, 62.0] {
            #expect(ReaderLayoutMetrics.headerBarTopOffset(safeTop: safeArea, edgeDistance: 0) == 0)
            #expect(ReaderLayoutMetrics.footerBarBottomOffset(safeBottom: safeArea, edgeDistance: 0) == 0)
            let insets = ReaderLayoutMetrics.barContentInsets(
                safeTop: safeArea, safeBottom: safeArea, showsHeader: true, showsFooter: true,
                verticalMargin: 12, headerExtent: 18, footerExtent: 18,
                edgeDistances: .init(header: 0, footer: 0)
            )
            #expect(insets.top == 30)
            #expect(insets.bottom == 30)
        }
    }

    @Test("Editing the header leaves the footer untouched and allows wider distances")
    func independentDistances() {
        let distances = ReaderBarEdgeDistances(header: 200)
        #expect(ReaderLayoutMetrics.headerBarTopOffset(safeTop: 59, edgeDistance: distances.header) == 200)
        #expect(ReaderLayoutMetrics.footerBarBottomOffset(safeBottom: 34, edgeDistance: distances.footer) == 38)
        let insets = ReaderLayoutMetrics.barContentInsets(
            safeTop: 59, safeBottom: 34, showsHeader: true, showsFooter: true,
            verticalMargin: 12, edgeDistances: distances
        )
        #expect(insets.top == 200 + ReaderLayoutMetrics.headerHeight + 12)
        #expect(insets.bottom == 38 + ReaderLayoutMetrics.footerHeight + 12)
    }

    @Test("Absolute distances survive layout saving, sync coding and preset import")
    func distancePersistence() throws {
        var layout = ReaderBarLayout.default
        layout.edgeDistances = .init(header: 0, footer: 180)
        let saved = ReaderBarLayoutPersistence.save(current: .default, proposed: layout) { _ in true }
        #expect(saved.didPersist)
        #expect(saved.layout.edgeDistances == layout.edgeDistances)
        let record = ReaderBarLayoutSyncRecord(layout: saved.layout, modifiedAt: Date(timeIntervalSince1970: 0))
        let synced = try JSONDecoder().decode(ReaderBarLayoutSyncRecord.self, from: JSONEncoder().encode(record))
        #expect(synced.layout.edgeDistances == layout.edgeDistances)

        let exported = ReaderBarLayoutMigration.freePositionLayout(from: synced.layout)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(exported))
        let preset = try ReaderLayoutPresetImporter.decode(data: JSONSerialization.data(withJSONObject: ["readerOverlayLayout": payload]))
        let imported = ReaderBarLayoutMigration.snap(try #require(preset.readerOverlayLayout))
        #expect(imported.edgeDistances == layout.edgeDistances)
        #expect(imported.fields == layout.fields)
    }
}
