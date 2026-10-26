import Testing
import Combine
import SwiftUI
import UIKit
@testable import yuedu_app

/// `DSColor`'s themed colours follow a theme switch in views that are not rebuilt.
/// Reproduced 2026-09-29 before the fix: a row with no inputs kept the old theme's text
/// colour, because the colour captured the themes when the row's body ran.
@Suite("Theme colour reactivity", .serialized)
@MainActor
struct ThemeColorReactivityTests {
    private final class Model: ObservableObject {
        @Published var themes: ActiveAppThemes
        init(themes: ActiveAppThemes) { self.themes = themes }
    }

    /// No inputs: once drawn, SwiftUI has no reason to rebuild it — a settings row.
    private struct Row: View {
        var body: some View {
            Rectangle().fill(DSColor.textPrimary).frame(width: 20, height: 20)
        }
    }

    /// Stands in for `ContentView`, which puts the themes in the environment.
    private struct Root: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack(spacing: 0) {
                Row()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .environment(\.appThemes, model.themes)
        }
    }

    @Test("a row SwiftUI does not rebuild follows a theme switch")
    func unrebuiltRowFollowsSwitch() async throws {
        let window = try Self.window()
        let model = Model(themes: Self.themes(text: .red))
        let host = UIHostingController(rootView: Root(model: model))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        #expect(Self.color(of: host.view, at: CGPoint(x: 10, y: 10)) == "red")

        model.themes = Self.themes(text: .blue)
        for _ in 0..<5 {
            await Task.yield()
            host.view.layoutIfNeeded()
        }
        #expect(Self.color(of: host.view, at: CGPoint(x: 10, y: 10)) == "blue")
    }

    @Test("a UIKit view follows the themes on its window")
    func uikitViewFollowsWindowTraits() throws {
        let window = try Self.window()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        view.backgroundColor = DSUIColor.textPrimary
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        window.traitOverrides[AppThemesTrait.self] = Self.themes(text: .red)
        view.updateTraitsIfNeeded()
        #expect(view.backgroundColor?.resolvedColor(with: view.traitCollection).rgbHex == UIColor.red.rgbHex)
        window.traitOverrides[AppThemesTrait.self] = Self.themes(text: .blue)
        view.updateTraitsIfNeeded()
        #expect(view.backgroundColor?.resolvedColor(with: view.traitCollection).rgbHex == UIColor.blue.rgbHex)
    }

    /// A UIKit view in dark draws the dark appearance's colours. Handed
    /// `UIColor(DSColor.x)`, it drew the light ones on iOS 17, where that conversion
    /// resolves in light whatever it is asked (measured 2026-10-26, iOS 17.5 — `DSUIColor`).
    @Test("a UIKit view draws the dark appearance's colours")
    func uikitViewDrawsDarkColours() throws {
        let window = try Self.window()
        window.overrideUserInterfaceStyle = .dark
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        view.backgroundColor = DSUIColor.groupedBackground
        #expect(Self.color(of: view, at: CGPoint(x: 10, y: 10)) == "rgb(0,0,0)")

        var light = AppearanceThemePreset.freeSolidPresets[0]
        light.authoredTextColors = AppearanceThemeTextColors(primary: .blue, secondary: .blue, tertiary: .blue)
        var dark = light
        dark.authoredTextColors = AppearanceThemeTextColors(primary: .red, secondary: .red, tertiary: .red)
        window.traitOverrides[AppThemesTrait.self] = ActiveAppThemes(light: light, dark: dark)
        view.backgroundColor = DSUIColor.textPrimary
        view.updateTraitsIfNeeded()
        #expect(Self.color(of: view, at: CGPoint(x: 10, y: 10)) == "red")
    }

    // MARK: - Helpers

    private static func themes(text: UIColor) -> ActiveAppThemes {
        var preset = AppearanceThemePreset.freeSolidPresets[0]
        preset.authoredTextColors = AppearanceThemeTextColors(primary: text, secondary: text, tertiary: text)
        return ActiveAppThemes(light: preset, dark: nil)
    }

    private static func window() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        window.overrideUserInterfaceStyle = .light
        return window
    }

    private static func color(of view: UIView, at point: CGPoint) -> String {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return "none" }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "none" }
        let x = point.x * image.scale, y = point.y * image.scale
        context.translateBy(x: -x, y: y - CGFloat(cgImage.height) + 1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        if bytes[0] > 200 && bytes[2] < 60 { return "red" }
        if bytes[2] > 200 && bytes[0] < 60 { return "blue" }
        return "rgb(\(bytes[0]),\(bytes[1]),\(bytes[2]))"
    }
}
