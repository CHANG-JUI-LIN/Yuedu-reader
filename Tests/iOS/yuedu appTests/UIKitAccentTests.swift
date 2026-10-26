import Testing
import SwiftUI
import UIKit
import WebKit
@testable import yuedu_app

/// UIKit inside SwiftUI takes the accent as `UIColor(DSColor.accent)`, which resolves from
/// the environment SwiftUI hands the view, so it draws what its SwiftUI neighbours draw — see
/// `DSUIColor`, which leaves the accent out for this reason. Resolved against traits built
/// by hand, the same colour is the light system blue on iOS 17 (0,122,255 in dark) and
/// misses the theme on every iOS; inside a hosted view it was right on iOS 17.5 and 27.
/// Each point here is the app's own view, drawn in a dark window and read back as pixels.
@Suite("UIKit inside SwiftUI draws the accent", .serialized)
@MainActor
struct UIKitAccentTests {
    enum Accent: String, CaseIterable, CustomTestStringConvertible {
        /// 暮色橙 on screen, as `ContentView` sets a theme.
        case theme
        /// 默認: the system accent.
        case system
        /// 默認 with Increase Contrast.
        case systemIncreasedContrast
        /// 暮色橙 on screen, and a screen setting its own accent under it.
        case screenOverride

        var testDescription: String { rawValue }
    }

    /// The accent `screenOverride`'s screen sets.
    private static let screenAccent = UIColor(red: 0.2, green: 0.65, blue: 0.35, alpha: 1)

    @Test("in dark, the 簡介 link, the iOS 17 search selection and the 青空 index draw the accent",
          arguments: Accent.allCases)
    func darkWindowDrawsAccent(_ accent: Accent) async throws {
        let preset = try #require(AppearanceThemePreset.freeSolidPresets.first { $0.id == "sunset_orange" })
        let themed = accent == .theme || accent == .screenOverride
        let themes = themed ? ActiveAppThemes(light: preset, dark: preset.palette(for: .dark)) : ActiveAppThemes()
        let darkTraits = UITraitCollection { traits in
            traits.userInterfaceStyle = .dark
            traits.accessibilityContrast = accent == .systemIncreasedContrast ? .high : .normal
        }
        let expected: UIColor
        switch accent {
        case .theme: expected = try #require(themes.dark).accent
        case .system, .systemIncreasedContrast: expected = UIColor.systemBlue.resolvedColor(with: darkTraits)
        case .screenOverride: expected = Self.screenAccent
        }

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        window.overrideUserInterfaceStyle = .dark
        if accent == .systemIncreasedContrast { window.traitOverrides.accessibilityContrast = .high }
        window.traitOverrides[AppThemesTrait.self] = themes
        let screenAccent = accent == .screenOverride ? Color(uiColor: Self.screenAccent) : nil
        let appAccent = themes.dark?.accentColor
        let host = UIHostingController(rootView: AccentPoints(screenAccent: screenAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black)
            // As `ContentView` sets them.
            .tint(appAccent).accentColor(appAccent)
            .environment(\.appThemes, themes))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        _ = Self.snapshot(host.view)
        for _ in 0..<10 {
            await Task.yield()
            host.view.layoutIfNeeded()
        }
        let image = Self.snapshot(host.view)

        // 簡介: the link colour the page hands WebKit.
        let webView = try #require(Self.first(WKWebView.self, in: host.view))
        let document = try #require((webView.navigationDelegate as? BookIntroWebView.Coordinator)?.loadedDocument)
        let link = try #require(Self.linkColour(in: document), "no link colour in the 簡介's CSS")
        #expect(Self.matches(link, expected), "簡介 link \(Self.describe(link)), expected \(Self.describe(expected))")

        // 青空's index, iOS 25 and earlier: the letters' colour.
        let searchController = try #require(Self.first(IOS17SearchResultTableViewController.self, in: host))
        let indexTable = try #require(Self.tables(in: host.view).first { $0 !== searchController.tableView })
        let indexFrame = indexTable.convert(indexTable.bounds, to: host.view)
        let strip = CGRect(x: indexFrame.maxX - 18, y: indexFrame.minY + 4, width: 16, height: indexFrame.height - 8)
        let drawnLetters = try Self.mostCommonSaturated(in: image, rect: strip)
        let letters = try #require(drawnLetters, "no index letters drawn")
        #expect(Self.matches(letters, expected), "青空 index \(Self.describe(letters)), expected \(Self.describe(expected))")

        // iOS 17's search results: the selected row's wash over what was under it.
        let table = try #require(searchController.tableView)
        let path = IndexPath(row: 0, section: 0)
        let cell = try #require(table.cellForRow(at: path))
        let cellFrame = cell.convert(cell.bounds, to: host.view)
        // Clear of the cover and the text, at the row's trailing edge.
        let spot = CGRect(x: cellFrame.maxX - 9, y: cellFrame.midY - 1, width: 2, height: 2)
        let ground = try Self.pixel(of: image, in: spot)
        table.selectRow(at: path, animated: false, scrollPosition: .none)
        table.layoutIfNeeded()
        let selected = try Self.pixel(of: Self.snapshot(host.view), in: spot)
        let wash = Self.composite(expected, alpha: 0.15, over: ground)
        #expect(Self.matches(selected, wash), "search selection \(Self.describe(selected)), expected \(Self.describe(wash))")
    }

    // MARK: - Helpers

    private static func snapshot(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private struct RGB {
        var red: Int
        var green: Int
        var blue: Int
    }

    private static func rgb(_ color: UIColor) -> RGB {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(red: Int((red * 255).rounded()), green: Int((green * 255).rounded()), blue: Int((blue * 255).rounded()))
    }

    /// Within one step per channel: compositing rounds (measured 1,20,38 against 2,20,38).
    private static func matches(_ drawn: UIColor, _ expected: UIColor) -> Bool {
        let a = rgb(drawn), b = rgb(expected)
        return abs(a.red - b.red) <= 1 && abs(a.green - b.green) <= 1 && abs(a.blue - b.blue) <= 1
    }

    private static func describe(_ color: UIColor) -> String {
        let value = rgb(color)
        return "\(value.red),\(value.green),\(value.blue)"
    }

    private static func composite(_ color: UIColor, alpha: CGFloat, over ground: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ground.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 * alpha + r2 * (1 - alpha),
            green: g1 * alpha + g2 * (1 - alpha),
            blue: b1 * alpha + b2 * (1 - alpha),
            alpha: 1
        )
    }

    /// `a{color:rgba(r,g,b,a)}` in the 簡介's style sheet.
    private static func linkColour(in document: String) -> UIColor? {
        guard let match = document.firstMatch(of: #/a\{color:rgba\(([0-9]+),([0-9]+),([0-9]+),/#),
              let red = Int(match.1), let green = Int(match.2), let blue = Int(match.3)
        else { return nil }
        return UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// The image's opaque pixels inside `rect`, in points from its top-left corner.
    private static func pixels(of image: UIImage, in rect: CGRect) throws -> [UIColor] {
        let cgImage = try #require(image.cgImage)
        let x = Int(rect.minX * image.scale), y = Int(rect.minY * image.scale)
        let width = max(Int(rect.width * image.scale), 1), height = max(Int(rect.height * image.scale), 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: CGFloat(-x), y: CGFloat(height - cgImage.height + y))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        var colors: [UIColor] = []
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 200 {
            let red = CGFloat(bytes[offset]) / 255
            let green = CGFloat(bytes[offset + 1]) / 255
            let blue = CGFloat(bytes[offset + 2]) / 255
            colors.append(UIColor(red: red, green: green, blue: blue, alpha: 1))
        }
        return colors
    }

    private static func pixel(of image: UIImage, in rect: CGRect) throws -> UIColor {
        try #require(try pixels(of: image, in: rect).first)
    }

    /// The most common strongly coloured pixel: the index letters, among the grey grounds
    /// of the table and its cells and the letters' anti-aliased edges.
    private static func mostCommonSaturated(in image: UIImage, rect: CGRect) throws -> UIColor? {
        var counts: [String: (color: UIColor, count: Int)] = [:]
        for pixel in try pixels(of: image, in: rect) {
            let value = rgb(pixel)
            let spread = max(value.red, value.green, value.blue) - min(value.red, value.green, value.blue)
            guard spread > 80 else { continue }
            let key = describe(pixel)
            counts[key] = (pixel, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.max { $0.count < $1.count }?.color
    }

    private static func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }

    private static func first<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let match = controller as? T { return match }
        for child in controller.children {
            if let match = first(type, in: child) { return match }
        }
        return nil
    }

    private static func tables(in view: UIView) -> [UITableView] {
        (view as? UITableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }
}

/// The three UIKit views that draw the accent, as the app builds them.
private struct AccentPoints: View {
    /// A screen's own accent over the app's. Applied only when set: `.tint(nil)` would put
    /// the system accent back.
    let screenAccent: Color?
    @State private var introLayout = BookIntroLayout()

    var body: some View {
        if let screenAccent {
            points.tint(screenAccent).accentColor(screenAccent)
        } else {
            points
        }
    }

    private var points: some View {
        VStack(spacing: 0) {
            BookIntroWebView(
                markup: #"<a href="https://example.com">連結</a>"#,
                mode: .fragment,
                baseURL: nil,
                layout: $introLayout
            )
            .frame(height: 60)
            IOS17SearchResultTable(
                content: IOS17SearchResultTableContent(rows: [
                    IOS17SearchResultTableRow(
                        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                        content: SearchBookListRowContent(title: "書", titleTag: nil, author: "作者", detail: "小說"),
                        coverURL: ""
                    ),
                ]),
                onSelect: { _ in }
            )
            .frame(height: 120)
            AozoraIndexedTable(
                groups: ["あ", "か", "さ", "た", "な", "は", "ま", "や"].map {
                    AozoraIndexGroup(id: $0, titleKey: $0, ids: ["\($0)1"])
                },
                row: { Text($0) },
                select: { _ in }
            )
            .frame(height: 440)
        }
    }
}
