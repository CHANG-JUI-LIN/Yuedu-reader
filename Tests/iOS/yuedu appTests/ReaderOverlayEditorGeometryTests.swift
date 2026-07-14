import CoreGraphics
import Testing
@testable import yuedu_app

struct ReaderOverlayEditorGeometryTests {
    private let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let safeArea = CGRect(x: 0, y: 59, width: 390, height: 751)
    private let menuSize = CGSize(width: 156, height: 48)

    @Test("editor snapping uses separate acquire and release distances")
    func snapHysteresis() {
        #expect(ReaderOverlayEditorGeometry.snapAcquireDistance == 6)
        #expect(ReaderOverlayEditorGeometry.snapReleaseDistance == 12)
    }

    @Test("anchored menu appears below when safe space is available")
    func menuBelowComponent() {
        let component = CGRect(x: 100, y: 200, width: 80, height: 44)
        let center = ReaderOverlayEditorGeometry.actionMenuCenter(
            componentFrame: component,
            menuSize: menuSize,
            canvas: canvas,
            safeArea: safeArea,
            gap: 8
        )

        #expect(center == CGPoint(x: component.midX, y: component.maxY + 8 + 24))
    }

    @Test("anchored menu moves above near the bottom safe area")
    func menuAboveComponent() {
        let component = CGRect(x: 100, y: 770, width: 80, height: 40)
        let center = ReaderOverlayEditorGeometry.actionMenuCenter(
            componentFrame: component,
            menuSize: menuSize,
            canvas: canvas,
            safeArea: safeArea,
            gap: 8
        )

        #expect(center.y == component.minY - 8 - 24)
    }

    @Test("anchored menu clamps horizontally inside the safe area")
    func menuClampsHorizontally() {
        let insetSafeArea = CGRect(x: 20, y: 59, width: 350, height: 751)
        let component = CGRect(x: 0, y: 200, width: 44, height: 44)
        let center = ReaderOverlayEditorGeometry.actionMenuCenter(
            componentFrame: component,
            menuSize: menuSize,
            canvas: canvas,
            safeArea: insetSafeArea,
            gap: 8
        )

        #expect(center.x == insetSafeArea.minX + menuSize.width / 2)
    }

    @Test("invalid safe area falls back to the canvas")
    func invalidSafeAreaFallsBack() {
        let component = CGRect(x: 0, y: 20, width: 20, height: 20)
        let center = ReaderOverlayEditorGeometry.actionMenuCenter(
            componentFrame: component,
            menuSize: menuSize,
            canvas: canvas,
            safeArea: .zero,
            gap: 8
        )

        #expect(center.x == menuSize.width / 2)
        #expect(center.y >= menuSize.height / 2)
    }

    @Test("anchored menu stays below the editor toolbar")
    func menuAvoidsTopChrome() {
        let topChrome = CGRect(x: 0, y: 0, width: 390, height: 123)
        let bottomChrome = CGRect(x: 0, y: 754, width: 390, height: 90)
        let menuSafeArea = ReaderOverlayEditorGeometry.chromeAvoidingSafeArea(
            safeArea: safeArea,
            canvas: canvas,
            topChromeFrame: topChrome,
            bottomChromeFrame: bottomChrome,
            gap: 8
        )
        let component = CGRect(x: 100, y: 60, width: 80, height: 40)
        let center = ReaderOverlayEditorGeometry.actionMenuCenter(
            componentFrame: component,
            menuSize: menuSize,
            canvas: canvas,
            safeArea: menuSafeArea,
            gap: 8
        )

        #expect(center.y - menuSize.height / 2 >= menuSafeArea.minY)
    }

    @Test("anchored menu stays above add and undo controls")
    func menuAvoidsBottomChrome() {
        let topChrome = CGRect(x: 0, y: 0, width: 390, height: 123)
        let bottomChrome = CGRect(x: 0, y: 690, width: 390, height: 154)
        let menuSafeArea = ReaderOverlayEditorGeometry.chromeAvoidingSafeArea(
            safeArea: safeArea,
            canvas: canvas,
            topChromeFrame: topChrome,
            bottomChromeFrame: bottomChrome,
            gap: 8
        )
        let component = CGRect(x: 100, y: 780, width: 80, height: 40)
        let center = ReaderOverlayEditorGeometry.actionMenuCenter(
            componentFrame: component,
            menuSize: menuSize,
            canvas: canvas,
            safeArea: menuSafeArea,
            gap: 8
        )

        #expect(center.y + menuSize.height / 2 <= menuSafeArea.maxY)
    }

    @Test("save errors and accessibility text sizes use measured chrome frames")
    func measuredChromeFramesIncludeDynamicHeight() {
        let tallTopChrome = CGRect(x: 0, y: 0, width: 390, height: 196)
        let tallBottomChrome = CGRect(x: 0, y: 620, width: 390, height: 224)

        let menuSafeArea = ReaderOverlayEditorGeometry.chromeAvoidingSafeArea(
            safeArea: safeArea,
            canvas: canvas,
            topChromeFrame: tallTopChrome,
            bottomChromeFrame: tallBottomChrome,
            gap: 8
        )

        #expect(menuSafeArea.minY == tallTopChrome.maxY + 8)
        #expect(menuSafeArea.maxY == tallBottomChrome.minY - 8)
    }

}
