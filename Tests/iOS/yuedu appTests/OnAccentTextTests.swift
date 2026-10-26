import Testing
import Combine
import SwiftUI
import UIKit
@testable import yuedu_app

/// `DSColor.textOnAccent` turns black on an accent too light for white. Feedback #77: an
/// imported pack whose dark accent is near white (玉桂狗) drew the selected shelf chip
/// white on white, the token having been `Color.white`.
@Suite("Text on the accent", .serialized)
@MainActor
struct OnAccentTextTests {
    private static let nearWhite = rgb(0xF5F5F5)
    private static let darkNavy = rgb(0x1F2A58)

    // MARK: - The choice

    @Test("a near-white accent takes black text, a dark one white")
    func contrastChoice() {
        #expect(DSColor.prefersDarkText(onAccent: Self.nearWhite))
        #expect(!DSColor.prefersDarkText(onAccent: Self.darkNavy))
    }

    @Test("the system blues keep white; 琥珀金 and 苔原綠's dark accent take black")
    func builtInAccents() throws {
        #expect(!DSColor.prefersDarkText(onAccent: Self.rgb(0x007AFF)))
        #expect(!DSColor.prefersDarkText(onAccent: Self.rgb(0x0A84FF)))

        let forest = try Self.preset("forest_green")
        #expect(!DSColor.prefersDarkText(onAccent: Self.rgb(forest.accent)))
        #expect(DSColor.prefersDarkText(onAccent: Self.rgb(forest.palette(for: .dark).accent)))
        let amber = try Self.preset("amber_gold")
        #expect(DSColor.prefersDarkText(onAccent: Self.rgb(amber.accent)))
    }

    @Test("extended-range components are judged as their sRGB clamp")
    func extendedRange() {
        #expect(DSColor.prefersDarkText(onAccent: CoverTint.RGB(red: 1.1, green: 1.05, blue: 1.2)))
        #expect(!DSColor.prefersDarkText(onAccent: CoverTint.RGB(red: -0.05, green: 0.1, blue: 0.3)))
    }

    // MARK: - The token as drawn

    /// The accents a view can draw under: none (the system blue), a theme's as
    /// `ContentView` sets it, and `.tint` alone.
    enum Accent: String, CaseIterable, Sendable {
        case system
        case themeNearWhite
        case themeDark
        case tintOnlyNearWhite
    }

    @Test("the token answers the accent its fill draws", arguments: Accent.allCases)
    func tokenPairsWithFill(_ accent: Accent) throws {
        let (fill, text) = try Self.drawnSwatches(under: accent)
        let textIsDark = CoverTint.luminance(text) < 0.5
        #expect(textIsDark == DSColor.prefersDarkText(onAccent: fill), "fill \(fill), text \(text)")
        // Under a theme the fill must be the theme's, or the pairing above proves nothing.
        switch accent {
        case .system:
            #expect(!textIsDark)
        case .themeNearWhite:
            #expect(CoverTint.luminance(fill) > 0.8)
            #expect(textIsDark)
        case .themeDark:
            #expect(CoverTint.luminance(fill) < 0.05)
            #expect(!textIsDark)
        case .tintOnlyNearWhite:
            break
        }
    }

    /// The purchase buttons tint their spinner with the token inside a prominent button,
    /// whose fill is the tint: resolving it must not read itself back.
    @Test("a spinner tinted with the token in a prominent button draws")
    func spinnerInProminentButton() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 80)
        let accent = Self.nearWhite.color
        let host = UIHostingController(rootView:
            Button {} label: {
                ProgressView().tint(DSColor.textOnAccent).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .accentColor(accent)
        )
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        #expect(image.cgImage != nil)
    }

    private final class AccentModel: ObservableObject {
        @Published var accent: Color?
        init(accent: Color?) { self.accent = accent }
    }

    /// Stands in for `ContentView`: the accent set at the root, as a theme's is.
    private struct ChipRoot: View {
        @ObservedObject var model: AccentModel
        var body: some View {
            VStack(spacing: 0) {
                DSChip(title: "全部", isSelected: true) {}
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .tint(model.accent)
            .accentColor(model.accent)
        }
    }

    @Test("a selected chip under a near-white theme accent has dark text", arguments: [false, true])
    func selectedChipUnderTheme(switchesAfterFirstDraw: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 80)
        // A white page, so the only dark pixels are the chip's text.
        window.overrideUserInterfaceStyle = .light
        let model = AccentModel(accent: switchesAfterFirstDraw ? nil : Self.nearWhite.color)
        let host = UIHostingController(rootView: ChipRoot(model: model))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        _ = Self.snapshot(host.view)
        if switchesAfterFirstDraw {
            model.accent = Self.nearWhite.color
            for _ in 0..<5 {
                await Task.yield()
                host.view.layoutIfNeeded()
            }
        }
        let pixels = try Self.pixels(of: Self.snapshot(host.view))
        // F5F5F5 is 0.91; the page around it is 1.
        let capsule = pixels.filter { (0.85...0.95).contains(CoverTint.luminance($0)) }
        let darkest = pixels.map(CoverTint.luminance).min() ?? 1
        #expect(capsule.count > 50, "no near-white capsule drawn")
        #expect(darkest < 0.2, "darkest pixel luminance \(darkest)")
    }

    /// A chip whose body SwiftUI can skip: no stored properties, so a re-render above it
    /// reaches it only as an environment change — how a theme's tint reaches the shelf.
    private struct ChipLeaf: View {
        var body: some View {
            DSChip(title: "全部", isSelected: true) {}
        }
    }

    private struct LeafRoot: View {
        @ObservedObject var model: AccentModel
        var body: some View {
            VStack(spacing: 0) {
                ChipLeaf()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A white page in either appearance, so the only dark pixels are the text's.
            .background(Color.white)
            .ignoresSafeArea()
            .tint(model.accent)
            .accentColor(model.accent)
        }
    }

    /// Draws `LeafRoot`, lets `change` run, and returns the chip's pixels as drawn after it.
    private static func leafPixels(
        accent: Color?,
        style: UIUserInterfaceStyle,
        change: (AccentModel, UIWindow) -> Void
    ) async throws -> [CoverTint.RGB] {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 80)
        window.overrideUserInterfaceStyle = style
        let model = AccentModel(accent: accent)
        let host = UIHostingController(rootView: LeafRoot(model: model))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        _ = snapshot(host.view)
        change(model, window)
        for _ in 0..<5 {
            await Task.yield()
            host.view.layoutIfNeeded()
        }
        return try pixels(of: snapshot(host.view))
    }

    @Test("a drawn chip's text turns dark when only the accent above it changes to near white")
    func drawnChipFollowsAccentChange() async throws {
        let pixels = try await Self.leafPixels(accent: nil, style: .light) { model, _ in
            model.accent = Self.nearWhite.color
        }
        let capsule = pixels.filter { (0.85...0.95).contains(CoverTint.luminance($0)) }
        let darkest = pixels.map(CoverTint.luminance).min() ?? 1
        #expect(capsule.count > 50, "no near-white capsule drawn")
        #expect(darkest < 0.2, "darkest pixel luminance \(darkest)")
    }

    @Test("a drawn chip's text turns dark when the appearance flips under a per-appearance accent")
    func drawnChipFollowsAppearanceFlip() async throws {
        let nearWhite = UIColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255, alpha: 1)
        let navy = UIColor(red: 0x1F / 255, green: 0x2A / 255, blue: 0x58 / 255, alpha: 1)
        let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? nearWhite : navy })
        let pixels = try await Self.leafPixels(accent: accent, style: .light) { _, window in
            window.overrideUserInterfaceStyle = .dark
        }
        let capsule = pixels.filter { (0.85...0.95).contains(CoverTint.luminance($0)) }
        let darkest = pixels.map(CoverTint.luminance).min() ?? 1
        #expect(capsule.count > 50, "no near-white capsule drawn")
        #expect(darkest < 0.2, "darkest pixel luminance \(darkest)")
    }

    /// Records the accent a style resolves where it draws.
    private struct AccentProbe: ShapeStyle {
        nonisolated(unsafe) static var resolved: [CoverTint.RGB] = []
        func resolve(in environment: EnvironmentValues) -> Color.Resolved {
            let accent = Color.accentColor.resolve(in: environment)
            Self.resolved.append(CoverTint.RGB(red: Double(accent.red), green: Double(accent.green), blue: Double(accent.blue)))
            return accent
        }
    }

    /// The shelf's group bar: a safe-area bar of a scroll view in a navigation stack.
    @available(iOS 26.0, *)
    private struct ShelfBarRoot: View {
        let accent: Color
        var body: some View {
            NavigationStack {
                ScrollView {
                    Color.clear.frame(height: 600)
                }
                .safeAreaBar(edge: .top, spacing: 0) {
                    HStack(spacing: DSSpacing.sm) {
                        DSChip(title: "全部", isSelected: true) {}
                        Rectangle().fill(AccentProbe()).frame(width: 2, height: 2)
                    }
                    .padding(.horizontal, DSSpacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toolbarTitleDisplayMode(.inline)
            }
            .tint(accent)
            .accentColor(accent)
        }
    }

    @Test("a selected chip in the shelf's safe-area bar has dark text under a near-white accent")
    func selectedChipInSafeAreaBar() throws {
        guard #available(iOS 26.0, *) else { return }
        AccentProbe.resolved = []
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        window.overrideUserInterfaceStyle = .light
        let host = UIHostingController(rootView: ShelfBarRoot(accent: Self.nearWhite.color))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let image = Self.snapshot(host.view)
        let probes = AccentProbe.resolved.map { String(format: "%.2f,%.2f,%.2f", $0.red, $0.green, $0.blue) }
        #expect(AccentProbe.resolved.allSatisfy { CoverTint.luminance($0) > 0.8 }, "probe resolved \(probes)")
        let pixels = try Self.pixels(of: image, width: 320, height: 300)
        let darkest = pixels.map(CoverTint.luminance).min() ?? 1
        #expect(darkest < 0.2, "darkest pixel luminance \(darkest); probe resolved \(probes)")
    }

    // MARK: - Helpers

    private static func snapshot(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    /// The top-left `width`×`height` points of the image — by default where a chip at the
    /// origin sits.
    private static func pixels(of image: UIImage, width points: CGFloat = 120, height pointsHigh: CGFloat = 44) throws -> [CoverTint.RGB] {
        let cgImage = try #require(image.cgImage)
        let width = Int(points * image.scale), height = Int(pointsHigh * image.scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height - cgImage.height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return stride(from: 0, to: bytes.count, by: 4).compactMap { offset in
            guard bytes[offset + 3] > 200 else { return nil }
            return CoverTint.RGB(
                red: Double(bytes[offset]) / 255,
                green: Double(bytes[offset + 1]) / 255,
                blue: Double(bytes[offset + 2]) / 255
            )
        }
    }

    private static func rgb(_ hex: UInt32) -> CoverTint.RGB {
        CoverTint.RGB(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    private static func rgb(_ color: UIColor) -> CoverTint.RGB {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return CoverTint.RGB(red: red, green: green, blue: blue)
    }

    private static func preset(_ id: String) throws -> AppearanceThemePreset {
        try #require(AppearanceThemePreset.freeSolidPresets.first { $0.id == id })
    }

    /// Draws the accent fill beside the token and reads one pixel of each.
    private static func drawnSwatches(under accent: Accent) throws -> (fill: CoverTint.RGB, text: CoverTint.RGB) {
        let swatches = HStack(spacing: 0) {
            Rectangle().fill(DSColor.accent)
            Rectangle().fill(DSColor.textOnAccent)
        }
        .frame(width: 8, height: 4)
        let content: AnyView
        switch accent {
        case .system:
            content = AnyView(swatches)
        case .themeNearWhite:
            content = AnyView(swatches.tint(nearWhite.color).accentColor(nearWhite.color))
        case .themeDark:
            content = AnyView(swatches.tint(darkNavy.color).accentColor(darkNavy.color))
        case .tintOnlyNearWhite:
            content = AnyView(swatches.tint(nearWhite.color))
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: 8 * 4 * 4)
        let context = try #require(CGContext(
            data: &bytes, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 8 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 4))
        func pixel(x: Int) -> CoverTint.RGB {
            let offset = (1 * 8 + x) * 4
            return CoverTint.RGB(
                red: Double(bytes[offset]) / 255,
                green: Double(bytes[offset + 1]) / 255,
                blue: Double(bytes[offset + 2]) / 255
            )
        }
        return (pixel(x: 1), pixel(x: 5))
    }
}
