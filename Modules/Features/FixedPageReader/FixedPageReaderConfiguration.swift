import CoreGraphics
import Foundation

struct FixedPageReaderConfiguration: Equatable, Codable {
    enum Layout: String, Codable {
        case paged
        case continuousVerticalScroll
    }

    enum NavigationAxis: String, Codable {
        case horizontal
        case vertical
    }

    enum Progression: String, Codable {
        case rightToLeft
        case leftToRight
        case topToBottom
        case verticalScroll
    }

    enum FitMode: String, Codable {
        case fitPage
        case fitWidth
    }

    enum PageSpreadLayout: String, Codable, CaseIterable {
        case single
        case double
        case auto
    }

    var mode: FixedPageReadingMode
    var layout: Layout
    var navigationAxis: NavigationAxis
    var progression: Progression
    var fitMode: FitMode
    var pageSpacing: CGFloat
    var isZoomEnabled: Bool

    // Aidoku-inspired advanced features:
    var pageSpreadLayout: PageSpreadLayout
    var pageOffset: Bool
    var splitWideImages: Bool
    var cropBorders: Bool
    var pillarbox: Bool
    var pillarboxAmount: CGFloat
    var autoScrollSpeed: Int
    var isLiveTextEnabled: Bool

    init(
        mode: FixedPageReadingMode,
        layout: Layout,
        navigationAxis: NavigationAxis,
        progression: Progression,
        fitMode: FitMode,
        pageSpacing: CGFloat,
        isZoomEnabled: Bool,
        pageSpreadLayout: PageSpreadLayout = .single,
        pageOffset: Bool = false,
        splitWideImages: Bool = false,
        cropBorders: Bool = false,
        pillarbox: Bool = false,
        pillarboxAmount: CGFloat = 0.75,
        autoScrollSpeed: Int = 3,
        isLiveTextEnabled: Bool = true
    ) {
        self.mode = mode
        self.layout = layout
        self.navigationAxis = navigationAxis
        self.progression = progression
        self.fitMode = fitMode
        self.pageSpacing = pageSpacing
        self.isZoomEnabled = isZoomEnabled
        self.pageSpreadLayout = pageSpreadLayout
        self.pageOffset = pageOffset
        self.splitWideImages = splitWideImages
        self.cropBorders = cropBorders
        self.pillarbox = pillarbox
        self.pillarboxAmount = pillarboxAmount
        self.autoScrollSpeed = autoScrollSpeed
        self.isLiveTextEnabled = isLiveTextEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(FixedPageReadingMode.self, forKey: .mode)
        layout = try container.decode(Layout.self, forKey: .layout)
        navigationAxis = try container.decode(NavigationAxis.self, forKey: .navigationAxis)
        progression = try container.decode(Progression.self, forKey: .progression)
        fitMode = try container.decode(FitMode.self, forKey: .fitMode)
        pageSpacing = try container.decode(CGFloat.self, forKey: .pageSpacing)
        isZoomEnabled = try container.decode(Bool.self, forKey: .isZoomEnabled)
        pageSpreadLayout = try container.decodeIfPresent(PageSpreadLayout.self, forKey: .pageSpreadLayout) ?? .single
        pageOffset = try container.decodeIfPresent(Bool.self, forKey: .pageOffset) ?? false
        splitWideImages = try container.decodeIfPresent(Bool.self, forKey: .splitWideImages) ?? false
        cropBorders = try container.decodeIfPresent(Bool.self, forKey: .cropBorders) ?? false
        pillarbox = try container.decodeIfPresent(Bool.self, forKey: .pillarbox) ?? false
        pillarboxAmount = try container.decodeIfPresent(CGFloat.self, forKey: .pillarboxAmount) ?? 0.75
        autoScrollSpeed = try container.decodeIfPresent(Int.self, forKey: .autoScrollSpeed) ?? 3
        isLiveTextEnabled = try container.decodeIfPresent(Bool.self, forKey: .isLiveTextEnabled) ?? true
    }

    static func recommendedDefault(for mode: FixedPageReadingMode) -> FixedPageReaderConfiguration {
        mode.recommendedConfiguration
    }
}

extension FixedPageReadingMode {
    var recommendedConfiguration: FixedPageReaderConfiguration {
        switch self {
        case .rtl:
            return FixedPageReaderConfiguration(
                mode: self,
                layout: .paged,
                navigationAxis: .horizontal,
                progression: .rightToLeft,
                fitMode: .fitPage,
                pageSpacing: 8,
                isZoomEnabled: true
            )
        case .ltr:
            return FixedPageReaderConfiguration(
                mode: self,
                layout: .paged,
                navigationAxis: .horizontal,
                progression: .leftToRight,
                fitMode: .fitPage,
                pageSpacing: 8,
                isZoomEnabled: true
            )
        case .vertical:
            return FixedPageReaderConfiguration(
                mode: self,
                layout: .paged,
                navigationAxis: .vertical,
                progression: .topToBottom,
                fitMode: .fitPage,
                pageSpacing: 8,
                isZoomEnabled: true
            )
        case .webtoon:
            return FixedPageReaderConfiguration(
                mode: self,
                layout: .continuousVerticalScroll,
                navigationAxis: .vertical,
                progression: .verticalScroll,
                fitMode: .fitWidth,
                pageSpacing: 0,
                isZoomEnabled: true // Enable zoom in webtoon!
            )
        }
    }

    static func savedConfiguration(
        for bookId: UUID,
        defaults: UserDefaults = .standard
    ) -> FixedPageReaderConfiguration {
        saved(for: bookId, defaults: defaults).recommendedConfiguration
    }
}
