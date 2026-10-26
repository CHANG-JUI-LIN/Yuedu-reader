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
            .buttonStyle(.onAccentProminent)
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

    // MARK: - Prominent buttons

    /// A prominent button on the accent as its sites build it. Every `.onAccentProminent` and
    /// `.onAccentGlassProminent` site is one of these. The system's own prominent styles drew
    /// all of them white on a near-white accent (iOS 27.0: 1.09 on F5F5F5, 1.14 on E6F2F4).
    enum ProminentShape: String, CaseIterable, Sendable {
        /// Around a `Text`: 升級, 新增欄目, 產生推薦, 重試, 開始使用, 申請加入, the purchases.
        case text
        /// Around a `Label` with a symbol: 以網頁開啟, 開啟網頁, 播放, 執行, 訂閱 Pro 繼續編輯筆記.
        case label
        /// `.controlSize(.large)`, as wide as it is offered: 確認匯入 and the import result's action.
        case large
        /// The tint set on the button itself: `sourceFilterButtonStyle` before iOS 26.
        case tintOnButton
        /// In a `ContentUnavailableView`'s actions inside a `Form`: 升級 on the AI pages.
        case inFormUnavailable
        /// `.onAccentGlassProminent` with the tint on the button: `sourceFilterButtonStyle`.
        case glassTintOnButton
        /// The tour's 繼續: a large glass capsule.
        case glassCapsuleLarge

        var isGlass: Bool { self == .glassTintOnButton || self == .glassCapsuleLarge }
    }

    /// An accent and an appearance a prominent button is drawn under.
    struct Ground: Sendable, CustomTestStringConvertible {
        /// nil: no theme, the system blue.
        let accent: UInt32?
        let dark: Bool
        /// Only `.tint` set, no `.accentColor`.
        var tintOnly = false

        var testDescription: String {
            "\(accent.map { String(format: "%06X", $0) } ?? "system") \(dark ? "dark" : "light")\(tintOnly ? " tint only" : "")"
        }

        /// Near white twice, 琥珀金 (just under white's 3:1), a dark navy, and none.
        static let themed: [Ground] = ([0xF5F5F5, 0xE6F2F4, 0xD69A2D, 0x1F2A58, nil] as [UInt32?]).flatMap { accent in
            [false, true].map { Ground(accent: accent, dark: $0) }
        }
    }

    @Test("a prominent button's label contrasts with the accent it is drawn on",
          arguments: ProminentShape.allCases, Ground.themed)
    func prominentLabel(_ shape: ProminentShape, on ground: Ground) async throws {
        if shape.isGlass {
            guard #available(iOS 26.0, *) else { return }
        }
        let drawn = try await Self.drawButton(dark: ground.dark) {
            ProminentRoot(shape: shape, ground: ground)
        }
        let line = Self.describe(drawn, "\(shape.rawValue) \(ground.testDescription)")
        print(line)
        // The fill must be the accent's, or the label's contrast says nothing about it.
        switch ground.accent {
        case 0xF5F5F5?, 0xE6F2F4?: #expect(CoverTint.luminance(drawn.fill) > 0.75, "\(line)")
        case 0x1F2A58?: #expect(CoverTint.luminance(drawn.fill) < 0.08, "\(line)")
        default: break
        }
        let labelIsDark = CoverTint.luminance(drawn.label) < 0.2
        let wantsDark = ground.accent.map { DSColor.prefersDarkText(onAccent: Self.rgb($0)) } ?? false
        #expect(labelIsDark == wantsDark, "\(line)")
        #expect(CoverTint.contrast(drawn.fill, drawn.label) >= DSColor.onAccentMinimumWhiteContrast, "\(line)")
    }

    /// `.tint` alone fills a prominent button but leaves `Color.accentColor`, which the token
    /// reads, where it was: measured white on F5F5F5 for every shape that takes the tint from
    /// above (iOS 27.0; inside a `Form` the accent colour did follow). So the tour's overlay and
    /// the chapter failure card set `.accentColor` beside their `.tint`. When this fails, the
    /// accent colour follows the tint and those two `.accentColor` can go.
    @Test("tint alone does not reach the accent colour the token reads", arguments: [false, true])
    func tintAloneLeavesAccentColor(dark: Bool) async throws {
        let ground = Ground(accent: 0xF5F5F5, dark: dark, tintOnly: true)
        let drawn = try await Self.drawButton(dark: dark) {
            ProminentRoot(shape: .text, ground: ground)
        }
        let line = Self.describe(drawn, "text \(ground.testDescription)")
        print(line)
        #expect(CoverTint.luminance(drawn.fill) > 0.75, "\(line)")
        #expect(CoverTint.luminance(drawn.label) > 0.8, "\(line)")
    }

    @Test("a disabled prominent button draws the system's label, not the token",
          arguments: [Ground(accent: 0xF5F5F5, dark: false), Ground(accent: 0xF5F5F5, dark: true),
                      Ground(accent: nil, dark: false), Ground(accent: nil, dark: true)])
    func disabledProminentLabel(on ground: Ground) async throws {
        let accent = ground.accent.map { Self.rgb($0).color }
        let system = try await Self.drawButton(dark: ground.dark) {
            Button(ProminentRoot.title) {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .recordsFrame()
                .themed(accent)
        }
        let styled = try await Self.drawButton(dark: ground.dark) {
            Button(ProminentRoot.title) {}
                .buttonStyle(.onAccentProminent)
                .disabled(true)
                .recordsFrame()
                .themed(accent)
        }
        let lines = Self.describe(system, "system \(ground.testDescription)") + "\n" + Self.describe(styled, "styled")
        print(lines)
        #expect(abs(CoverTint.luminance(system.fill) - CoverTint.luminance(styled.fill)) < 0.02, "\(lines)")
        #expect(abs(CoverTint.luminance(system.label) - CoverTint.luminance(styled.label)) < 0.02, "\(lines)")
    }

    @Test("a styled prominent button is one VoiceOver button that keeps its identifier")
    func prominentButtonAccessibility() async throws {
        func elements(_ style: some PrimitiveButtonStyle) async throws -> [String] {
            try await Self.accessibilityElements {
                Button {} label: { Text(verbatim: "升級") }
                    .buttonStyle(style)
                    .accessibilityIdentifier("prominent.probe")
                    .themed(Self.nearWhite.color)
            }
        }
        let system = try await elements(.borderedProminent)
        let styled = try await elements(.onAccentProminent)
        #expect(system.count == 1 && system.first?.hasSuffix("|button|prominent.probe") == true, "system \(system)")
        #expect(styled == system, "styled \(styled)")
    }

    /// The purchase buttons, 申請加入 and 執行 stay on the accent while they work, a spinner tinted
    /// with the token for their label. Disabled, they drew the system's grey under it: 1.12:1 on
    /// the system blue in light appearance, 1.26:1 on a near-white accent in dark.
    @Test("a working button's spinner is on the accent and paired with it", arguments: Ground.themed)
    func spinnerOnAccent(on ground: Ground) async throws {
        let drawn = try await Self.drawButton(dark: ground.dark) {
            Button {} label: {
                ProgressView().tint(DSColor.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.onAccentProminent(working: true, title: Text(verbatim: "申請加入")))
            .recordsFrame()
            .padding(.horizontal, DSSpacing.md)
            .themed(ground.accent.map { Self.rgb($0).color })
        }
        let line = Self.describe(drawn, "spinner \(ground.testDescription)")
        print(line)
        // A spinner's spokes fade, so this asks only that it is the token's side of the fill:
        // the system's own white spinner on its blue peaks at 2.5:1.
        let spinnerIsDark = CoverTint.luminance(drawn.label) < 0.2
        let wantsDark = ground.accent.map { DSColor.prefersDarkText(onAccent: Self.rgb($0)) } ?? false
        #expect(spinnerIsDark == wantsDark, "\(line)")
        if ground.accent != nil {
            #expect(CoverTint.contrast(drawn.fill, drawn.label) >= DSColor.onAccentMinimumWhiteContrast, "\(line)")
        }
    }

    /// Working, the button stays enabled to keep the accent, and VoiceOver still hears it by its
    /// title and dimmed, with activation doing nothing. Measured 2026-10-26: its spinner alone
    /// left it nameless, enabled or disabled, and enabled it lost 「變暗」 as well.
    @Test("a working button is named and dimmed to VoiceOver, and ignores activation", arguments: [false, true])
    func workingButtonAccessibility(isWorking: Bool) async throws {
        final class Taps { var count = 0 }
        let taps = Taps()
        try await Self.withAccessibilityElements {
            Button { taps.count += 1 } label: {
                if isWorking {
                    ProgressView().tint(DSColor.textOnAccent)
                } else {
                    Text(verbatim: "申請加入")
                }
            }
            .buttonStyle(.onAccentProminent(working: isWorking, title: Text(verbatim: "申請加入")))
            .accessibilityIdentifier("working.probe")
            .themed(Self.nearWhite.color)
        } inspect: { objects in
            try #require(objects.count == 1, "\(objects)")
            let button = objects[0]
            #expect(button.accessibilityLabel == "申請加入")
            #expect(button.accessibilityTraits.contains(.button))
            #expect(button.accessibilityTraits.contains(.notEnabled) == isWorking)
            #expect(Self.identifier(of: button) == "working.probe")
            _ = button.accessibilityActivate()
            for _ in 0..<5 { await Task.yield() }
            #expect(taps.count == (isWorking ? 0 : 1))
        }
    }

    private static func describe(_ drawn: DrawnButton, _ name: String) -> String {
        String(
            format: "PROMINENT|%@|fill %.3f,%.3f,%.3f L%.3f|label %.3f,%.3f,%.3f L%.3f|contrast %.2f|frame %@",
            name,
            drawn.fill.red, drawn.fill.green, drawn.fill.blue, CoverTint.luminance(drawn.fill),
            drawn.label.red, drawn.label.green, drawn.label.blue, CoverTint.luminance(drawn.label),
            CoverTint.contrast(drawn.fill, drawn.label), NSCoder.string(for: drawn.frame)
        )
    }

    struct DrawnButton {
        /// The most common colour inside the button.
        let fill: CoverTint.RGB
        /// The pixel inside the button farthest from the fill in contrast.
        let label: CoverTint.RGB
        let frame: CGRect
    }

    /// Draws `content`, whose button records its frame (`recordsFrame()`), and reads the fill
    /// and the label inside that frame, clear of the shape's rounded ends and edge.
    private static func drawButton(dark: Bool, @ViewBuilder _ content: () -> some View) async throws -> DrawnButton {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 240)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        ProminentFrame.frame = .null
        let host = UIHostingController(rootView: content().frame(maxWidth: .infinity, maxHeight: .infinity))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        _ = snapshot(host.view)
        for _ in 0..<5 {
            await Task.yield()
            host.view.layoutIfNeeded()
        }
        let image = snapshot(host.view)
        let frame = ProminentFrame.frame
        try #require(!frame.isNull && frame.width > 8 && frame.height > 8, "no frame recorded: \(frame)")
        let region = frame.insetBy(dx: max(frame.height / 2, 6), dy: frame.height * 0.2)
        let pixels = try Self.pixels(of: image, in: region.intersection(host.view.bounds))
        try #require(!pixels.isEmpty)
        var counts: [UInt32: Int] = [:]
        for pixel in pixels { counts[hex(pixel), default: 0] += 1 }
        let mode = try #require(counts.max { $0.value < $1.value }?.key)
        let fill = rgb(mode)
        let label = try #require(pixels.max { CoverTint.contrast(fill, $0) < CoverTint.contrast(fill, $1) })
        return DrawnButton(fill: fill, label: label, frame: frame)
    }

    /// Each accessibility element VoiceOver would reach in `content`, as label|button|identifier.
    private static func accessibilityElements(@ViewBuilder _ content: () -> some View) async throws -> [String] {
        try await withAccessibilityElements(content) { objects in
            objects.map { object in
                "\(object.accessibilityLabel ?? "")|\(object.accessibilityTraits.contains(.button) ? "button" : "-")|\(identifier(of: object))"
            }
        }
    }

    // SwiftUI's elements answer `accessibilityIdentifier` without declaring the protocol.
    private static func identifier(of object: NSObject) -> String {
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        return object.responds(to: getter) ? (object.value(forKey: "accessibilityIdentifier") as? String ?? "") : ""
    }

    /// Hands `inspect` each accessibility element VoiceOver would reach in `content`, while it
    /// is still on screen.
    private static func withAccessibilityElements<T>(
        @ViewBuilder _ content: () -> some View,
        inspect: ([NSObject]) async throws -> T
    ) async throws -> T {
        // SwiftUI builds no accessibility elements until something reads them; turned on as
        // XCUITest does it (`AccessibilityHiddenOnlyWhenTests`), and back off after.
        let accessibility = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        typealias GetFlag = @convention(c) () -> Bool
        typealias SetFlag = @convention(c) (Bool) -> Void
        let automationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSAutomationEnabled")), to: GetFlag.self)
        let setAutomationEnabled = unsafeBitCast(try #require(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: SetFlag.self)
        let wasEnabled = automationEnabled()
        setAutomationEnabled(true)
        defer { setAutomationEnabled(wasEnabled) }

        let root = UIHostingController(rootView: VStack { Text(verbatim: "旁邊"); content() })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        func elements(in object: NSObject) -> [NSObject] {
            if object.isAccessibilityElement {
                return [object]
            }
            if let children = object.accessibilityElements as? [NSObject] {
                return children.flatMap(elements(in:))
            }
            return (object as? UIView)?.subviews.flatMap(elements(in:)) ?? []
        }
        func isMarker(_ object: NSObject) -> Bool { object.accessibilityLabel == "旁邊" }
        let deadline = ContinuousClock.now + .seconds(5)
        var found = elements(in: root.view)
        while !found.contains(where: isMarker), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            found = elements(in: root.view)
        }
        try #require(found.contains(where: isMarker), "the view never reached the accessibility tree")
        return try await inspect(found.filter { !isMarker($0) })
    }

    private static func hex(_ rgb: CoverTint.RGB) -> UInt32 {
        UInt32((rgb.red * 255).rounded()) << 16 | UInt32((rgb.green * 255).rounded()) << 8 | UInt32((rgb.blue * 255).rounded())
    }

    /// One prominent button built the way its sites build it, under the accent set at the root
    /// as `ContentView` sets it.
    private struct ProminentRoot: View {
        let shape: ProminentShape
        let ground: Ground

        static let title = "提供裝置識別碼並重試"

        var body: some View {
            let accent = ground.accent.map { OnAccentTextTests.rgb($0).color }
            if ground.tintOnly {
                button.tint(accent)
            } else {
                button.themed(accent)
            }
        }

        @ViewBuilder private var button: some View {
            switch shape {
            case .text:
                Button(Self.title) {}
                    .buttonStyle(.onAccentProminent)
                    .recordsFrame()
            case .label:
                Button {} label: {
                    Label(Self.title, systemImage: "safari")
                        .font(DSFont.subheadline.weight(.semibold))
                }
                .buttonStyle(.onAccentProminent)
                .recordsFrame()
            case .large:
                Button {} label: {
                    Label(Self.title, systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.onAccentProminent)
                .controlSize(.large)
                .recordsFrame()
                .padding(.horizontal, DSSpacing.md)
            case .tintOnButton:
                Button {} label: {
                    Text("\(Self.title) 12").font(DSFont.subheadline).monospacedDigit().lineLimit(1)
                }
                .buttonStyle(.onAccentProminent).buttonBorderShape(.capsule).tint(DSColor.accent)
                .recordsFrame()
            case .inFormUnavailable:
                Form {
                    ContentUnavailableView {
                        UnavailableLabel("需要 Pro", systemImage: "lock.fill")
                    } actions: {
                        Button(Self.title) {}
                            .buttonStyle(.onAccentProminent)
                            .recordsFrame()
                    }
                    .listRowBackground(Color.clear)
                }
            case .glassTintOnButton:
                if #available(iOS 26.0, *) {
                    Button {} label: {
                        Text("\(Self.title) 12").font(DSFont.subheadline).monospacedDigit().lineLimit(1)
                    }
                    .buttonStyle(.onAccentGlassProminent).buttonBorderShape(.capsule).tint(DSColor.accent)
                    .recordsFrame()
                }
            case .glassCapsuleLarge:
                if #available(iOS 26.0, *) {
                    Button {} label: {
                        Text(Self.title).font(DSFont.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.onAccentGlassProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .recordsFrame()
                    .padding(.horizontal, DSSpacing.xl)
                }
            }
        }
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
        try pixels(of: image, in: CGRect(x: 0, y: 0, width: points, height: pointsHigh))
    }

    /// The image's pixels inside `rect`, given in points from its top-left corner.
    private static func pixels(of image: UIImage, in rect: CGRect) throws -> [CoverTint.RGB] {
        let cgImage = try #require(image.cgImage)
        let x = Int(rect.minX * image.scale), y = Int(rect.minY * image.scale)
        let width = Int(rect.width * image.scale), height = Int(rect.height * image.scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: CGFloat(-x), y: CGFloat(height - cgImage.height + y))
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

/// Where the prominent button under test laid out, in window coordinates.
private enum ProminentFrame {
    nonisolated(unsafe) static var frame: CGRect = .null
}

private extension View {
    func recordsFrame() -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ProminentFrame.frame = $0 }
    }

    /// The accent as `ContentView` sets a theme's.
    func themed(_ accent: Color?) -> some View {
        tint(accent).accentColor(accent)
    }
}
