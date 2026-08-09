import SwiftUI
import Testing
@testable import yuedu_app

@Suite("Chapter title designer presentation")
struct ChapterTitleDesignerPresentationTests {
    @Test("compact environments use tabs and regular environments defer sizing to NavigationSplitView")
    func layoutPolicy() {
        #expect(ChapterTitleDesignerLayoutPolicy.resolve(width: 390, horizontalSizeClass: .compact) == .tabbed)
        #expect(ChapterTitleDesignerLayoutPolicy.resolve(width: 900, horizontalSizeClass: .regular) == .split)
        #expect(ChapterTitleDesignerLayoutPolicy.resolve(width: 520, horizontalSizeClass: .regular) == .split)
        #expect(ChapterTitleDesignerLayoutPolicy.resolve(width: 900, horizontalSizeClass: .compact) == .tabbed)
    }

    @Test("layer actions remain available without canvas gestures")
    func accessibleActions() {
        #expect(Set(ChapterTitleLayerAccessibleAction.allCases) == [
            .nudgeUp, .nudgeDown, .nudgeLeading, .nudgeTrailing,
            .grow, .shrink, .rotateClockwise, .rotateCounterclockwise,
            .moveForward, .moveBackward, .edit, .duplicate, .delete,
        ])
    }

    @Test("legacy-only persisted designs migrate before the designer opens")
    func legacyEntryMigration() throws {
        var style = ChapterTitleStyle.default
        style.advancedCSSEnabled = true
        style.design = ChapterTitleDesign(
            layers: [],
            legacySource: ChapterTitleLegacySource(
                light: style.lightTemplate,
                dark: style.darkTemplate
            )
        )

        let design = try ChapterTitleDesignerEntryDesign.resolve(style)

        #expect(!design.layers.isEmpty)
        #expect(design.legacySource?.light == style.lightTemplate)
    }
}
