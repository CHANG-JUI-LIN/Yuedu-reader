import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// 外觀主題's 淺色／深色 tab (2026-10-05).
///
/// The report: 跟隨系統 off, 單獨設定深色主題 on, the app dark. 淺色 on the tab turned the page
/// light under a white status bar and title, and 設定 was dark again on the way back — the
/// tab was a preview the page painted on itself, and the appearance held since 跟隨系統 was
/// turned off could not be changed at all.
@Suite("Appearance light and dark slots", .serialized)
@MainActor
struct AppearanceSlotTabTests {
    private let settings = GlobalSettings.shared

    private func restoringAppearance(_ body: () throws -> Void) rethrows {
        let follows = settings.appearanceFollowsSystem
        let pinned = settings.appearancePinnedColorScheme
        let separate = settings.appearanceUsesSeparateDarkTheme
        let preview = settings.appearanceSlotPreview
        defer {
            settings.appearanceSlotPreview = preview
            settings.appearanceFollowsSystem = follows
            settings.appearancePinnedColorScheme = pinned
            settings.appearanceUsesSeparateDarkTheme = separate
        }
        try body()
    }

    @Test("with 跟隨系統 off the tab is the app's appearance, and it stays")
    func theTabIsTheAppearanceWithFollowSystemOff() {
        restoringAppearance {
            settings.appearanceFollowsSystem = false
            settings.appearancePinnedColorScheme = .dark
            // Without a separate dark theme too: off, nothing else picks the appearance.
            settings.appearanceUsesSeparateDarkTheme = false
            #expect(settings.showsAppearanceSlotTab)

            settings.pickAppearanceSlot(.light)
            #expect(settings.appearancePinnedColorScheme == .light)
            #expect(settings.appearanceSlotPreview == nil)
            #expect(settings.appearanceWindowColorScheme == .light)
            // The tab shows the pick even before the window has redrawn in it.
            #expect(settings.appearanceSlotOnTab(windowColorScheme: .dark) == .light)
            #expect(UserDefaults.standard.string(forKey: "yd_appearance_pinned_color_scheme") == "light")

            // Back on 設定: still light.
            settings.endAppearanceSlotPreview()
            #expect(settings.appearanceWindowColorScheme == .light)
        }
    }

    @Test("with 跟隨系統 on the tab previews the other slot in the whole window until it ends")
    func theTabPreviewsWithFollowSystemOn() {
        restoringAppearance {
            settings.appearanceFollowsSystem = true
            settings.appearancePinnedColorScheme = .light
            settings.appearanceUsesSeparateDarkTheme = true
            settings.appearanceSlotPreview = nil
            #expect(settings.appearanceWindowColorScheme == nil)
            #expect(settings.appearanceSlotOnTab(windowColorScheme: .light) == .light)

            settings.pickAppearanceSlot(.dark)
            #expect(settings.appearanceWindowColorScheme == .dark)
            #expect(settings.appearanceSlotOnTab(windowColorScheme: .light) == .dark)
            #expect(settings.appearancePinnedColorScheme == .light)

            settings.endAppearanceSlotPreview()
            #expect(settings.appearanceSlotPreview == nil)
            #expect(settings.appearanceWindowColorScheme == nil)
            #expect(settings.appearanceSlotOnTab(windowColorScheme: .light) == .light)
        }
    }

    @Test("without a separate dark theme, 跟隨系統 on shows no tab and wears no preview")
    func noPreviewWithoutASeparateDarkTheme() {
        restoringAppearance {
            settings.appearanceFollowsSystem = true
            settings.appearanceUsesSeparateDarkTheme = true
            settings.pickAppearanceSlot(.dark)
            settings.appearanceUsesSeparateDarkTheme = false
            #expect(!settings.showsAppearanceSlotTab)
            #expect(settings.appearanceWindowColorScheme == nil)
        }
    }

    @Test("turning 跟隨系統 off keeps the appearance on the tab; on again, the device decides")
    func turningFollowSystemOffKeepsThePreviewedAppearance() {
        restoringAppearance {
            settings.appearanceFollowsSystem = true
            settings.appearanceUsesSeparateDarkTheme = true
            settings.pickAppearanceSlot(.dark)

            settings.setAppearanceFollowsSystem(false, currentColorScheme: .dark)
            #expect(settings.appearancePinnedColorScheme == .dark)
            #expect(settings.appearanceSlotPreview == nil)
            #expect(settings.appearanceWindowColorScheme == .dark)

            settings.setAppearanceFollowsSystem(true, currentColorScheme: .dark)
            #expect(settings.appearanceWindowColorScheme == nil)
        }
    }
}
