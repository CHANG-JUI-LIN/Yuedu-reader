import Combine
import Foundation
import SwiftUI

// MARK: - 書本文字轉換（只在閱讀器使用）
enum TextConversion: String, CaseIterable {
    case original = "原文"
    case toTraditional = "繁體"
    case toSimplified = "简体"
}

// MARK: - 翻頁動畫（對應 Koodo 滑動、Legado 仿真/滑動/覆蓋）
enum PageTurnStyle: String, CaseIterable {
    case slide = "滑動"       // 左右滑動過渡（預設）
    case cover = "覆蓋翻頁"   // 新頁滑入覆蓋舊頁（Legado 同款）
    case curl = "仿真翻書"   // 書頁捲曲效果
    case none = "無動畫"     // 立即切換
}

// MARK: - 閱讀主題
enum ReaderTheme: String, CaseIterable {
    case white = "白天"
    case sepia = "護眼"
    case night = "夜間"

    private static let userDefaultsKey = "yd_reader_theme"
    private static let lastLightThemeKey = "lastLightTheme"

    static func loadPersisted() -> ReaderTheme {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return ReaderTheme(rawValue: raw) ?? .sepia
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
        if self != .night {
            UserDefaults.standard.set(rawValue, forKey: Self.lastLightThemeKey)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .white: return .white
        case .sepia: return Color(red: 244 / 255, green: 236 / 255, blue: 216 / 255)
        case .night: return Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
        }
    }

    var textColor: Color {
        switch self {
        case .white: return Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)
        case .sepia: return Color(red: 91 / 255, green: 70 / 255, blue: 54 / 255)
        case .night: return Color(red: 217 / 255, green: 217 / 255, blue: 217 / 255)
        }
    }

    var barColor: Color {
        switch self {
        case .white: return Color(UIColor.systemBackground)
        case .sepia: return Color(red: 0.93, green: 0.91, blue: 0.83)
        case .night: return Color(red: 0.12, green: 0.12, blue: 0.12)
        }
    }

    var epubJSName: String {
        switch self {
        case .white: return "white"
        case .sepia: return "sepia"
        case .night: return "night"
        }
    }
}

enum ReaderConfigRefreshKind {
    case layout
    case appearance
}

@MainActor
final class ReaderConfig: ObservableObject {
    static let shared = ReaderConfig()

    @Published var fontSize: CGFloat
    @Published var lineHeightMultiple: CGFloat
    @Published var letterSpacing: CGFloat
    @Published var paragraphSpacingMultiplier: CGFloat
    @Published var pageMarginH: CGFloat
    @Published var pageMarginV: CGFloat
    @Published var theme: ReaderTheme

    var lineSpacing: CGFloat {
        max(0, (lineHeightMultiple - 1.0) * fontSize)
    }

    var paragraphSpacing: CGFloat {
        max(0, fontSize * paragraphSpacingMultiplier)
    }

    let refresh = PassthroughSubject<ReaderConfigRefreshKind, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var suppressRefresh = false

    private init() {
        let gs = GlobalSettings.shared
        fontSize = CGFloat(gs.readerFontSize)
        lineHeightMultiple = CGFloat(gs.lineHeightMultiple)
        letterSpacing = CGFloat(gs.letterSpacing)
        paragraphSpacingMultiplier = CGFloat(gs.paragraphSpacingMultiplier)
        pageMarginH = CGFloat(gs.pageMarginH)
        pageMarginV = CGFloat(gs.pageMarginV)
        theme = ReaderTheme.loadPersisted()
        setupBindings()
    }

    func syncFromGlobalSettings() {
        let gs = GlobalSettings.shared
        suppressRefresh = true
        fontSize = CGFloat(gs.readerFontSize)
        lineHeightMultiple = CGFloat(gs.lineHeightMultiple)
        letterSpacing = CGFloat(gs.letterSpacing)
        paragraphSpacingMultiplier = CGFloat(gs.paragraphSpacingMultiplier)
        pageMarginH = CGFloat(gs.pageMarginH)
        pageMarginV = CGFloat(gs.pageMarginV)
        theme = ReaderTheme.loadPersisted()
        suppressRefresh = false
    }

    private func setupBindings() {
        let layoutPublisher = Publishers.CombineLatest4($fontSize, $lineHeightMultiple, $letterSpacing, $paragraphSpacingMultiplier)
            .combineLatest($pageMarginH, $pageMarginV)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)

        layoutPublisher
            .dropFirst()
            .sink { [weak self] combined, marginH, marginV in
                guard let self else { return }
                let (fontSize, lineHeightMultiple, letterSpacing, paragraphSpacingMultiplier) = combined
                let gs = GlobalSettings.shared
                gs.readerFontSize = Double(fontSize)
                gs.lineHeightMultiple = Double(lineHeightMultiple)
                gs.letterSpacing = Double(letterSpacing)
                gs.paragraphSpacingMultiplier = Double(paragraphSpacingMultiplier)
                gs.pageMarginH = Double(marginH)
                gs.pageMarginV = Double(marginV)
                guard !self.suppressRefresh else { return }
                self.refresh.send(.layout)
            }
            .store(in: &cancellables)

        $theme
            .dropFirst()
            .sink { [weak self] theme in
                theme.persist()
                guard let self, !self.suppressRefresh else { return }
                self.refresh.send(.appearance)
            }
            .store(in: &cancellables)
    }
}

extension String {
    /// 書本文字 ICU 離線轉換
    func converted(to mode: TextConversion) -> String {
        switch mode {
        case .original: return self
        case .toTraditional:
            return self.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false)
                ?? self
        case .toSimplified:
            return self.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false)
                ?? self
        }
    }
}

func localized(_ key: String, bundle: Bundle = .main) -> String {
    NSLocalizedString(key, bundle: bundle, comment: "")
}

// MARK: - 全局設定（App 語言 + 書本轉換 + 閱讀器）
class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()
    @Published var textConversion: TextConversion {
        didSet { UserDefaults.standard.set(textConversion.rawValue, forKey: "yd_text_conv") }
    }
    @Published var lineHeightMultiple: Double {
        didSet { UserDefaults.standard.set(lineHeightMultiple, forKey: "yd_line_height_multiple") }
    }
    @Published var scrollMode: Bool {
        didSet { UserDefaults.standard.set(scrollMode, forKey: "yd_scroll_mode") }
    }
    @Published var readerBrightness: Double {
        didSet { UserDefaults.standard.set(readerBrightness, forKey: "yd_reader_brightness") }
    }
    @Published var followSystemBrightness: Bool {
        didSet {
            UserDefaults.standard.set(followSystemBrightness, forKey: "yd_follow_sys_brightness")
        }
    }
    @Published var letterSpacing: Double {
        didSet { UserDefaults.standard.set(letterSpacing, forKey: "yd_letter_spacing") }
    }
    @Published var paragraphSpacingMultiplier: Double {
        didSet { UserDefaults.standard.set(paragraphSpacingMultiplier, forKey: "yd_paragraph_spacing_mult") }
    }
    @Published var pageMarginH: Double {
        didSet { UserDefaults.standard.set(pageMarginH, forKey: "yd_page_margin_h") }
    }
    @Published var pageMarginV: Double {
        didSet { UserDefaults.standard.set(pageMarginV, forKey: "yd_page_margin_v") }
    }
    @Published var pageTurnStyle: PageTurnStyle {
        didSet { UserDefaults.standard.set(pageTurnStyle.rawValue, forKey: "yd_page_turn_style") }
    }
    @Published var readerWritingMode: ReaderWritingMode {
        didSet { UserDefaults.standard.set(readerWritingMode.rawValue, forKey: "yd_reader_writing_mode") }
    }
    @Published var selectedReaderFontPostScript: String? {
        didSet {
            if let selectedReaderFontPostScript, !selectedReaderFontPostScript.isEmpty {
                UserDefaults.standard.set(selectedReaderFontPostScript, forKey: "yd_reader_font_postscript")
            } else {
                UserDefaults.standard.removeObject(forKey: "yd_reader_font_postscript")
            }
        }
    }
    @Published var userFonts: [UserFontInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(userFonts) {
                UserDefaults.standard.set(data, forKey: "yd_user_fonts")
            }
        }
    }

    // MARK: - 閱讀器字體（跨 session 持久化）
    @Published var readerFontSize: Double {
        didSet { UserDefaults.standard.set(readerFontSize, forKey: "yd_reader_font_size") }
    }

    /// 由倍率換算出的行與行額外距離（pt）
    var lineSpacing: Double {
        max(0, (lineHeightMultiple - 1.0) * readerFontSize)
    }

    /// 由倍率換算出的段距（pt）
    var paragraphSpacing: Double {
        max(0, readerFontSize * paragraphSpacingMultiplier)
    }

    var localeIdentifier: String {
        Locale.autoupdatingCurrent.identifier
    }

    // MARK: - 網路設定
    @Published var searchConcurrency: Int {
        didSet { UserDefaults.standard.set(searchConcurrency, forKey: "yd_search_concurrency") }
    }
    @Published var searchAutoPauseCount: Int {
        didSet {
            UserDefaults.standard.set(searchAutoPauseCount, forKey: "yd_search_auto_pause_count")
        }
    }
    @Published var searchCacheDays: Int {
        didSet { UserDefaults.standard.set(searchCacheDays, forKey: "yd_search_cache_days") }
    }

    // MARK: - TTS 設定
    @Published var httpTtsUrlTemplate: String {
        didSet { UserDefaults.standard.set(httpTtsUrlTemplate, forKey: "yd_http_tts_url_template") }
    }

    // MARK: - 實驗性功能旗標

    @Published var useRenderableNodePipeline: Bool {
        didSet { UserDefaults.standard.set(useRenderableNodePipeline, forKey: "yd_use_renderable_node_pipeline") }
    }

    private init() {
        UserDefaults.standard.removeObject(forKey: "yd_app_lang")
        let rawConv = UserDefaults.standard.string(forKey: "yd_text_conv") ?? ""
        textConversion = TextConversion(rawValue: rawConv) ?? .original
        let persistedFontSize =
            (UserDefaults.standard.object(forKey: "yd_reader_font_size") as? Double) ?? 18.0
        readerFontSize = persistedFontSize

        if let savedLineHeightMultiple = UserDefaults.standard.object(forKey: "yd_line_height_multiple") as? Double {
            lineHeightMultiple = savedLineHeightMultiple
        } else if let legacyLineSpacing = UserDefaults.standard.object(forKey: "yd_line_spacing") as? Double {
            lineHeightMultiple = max(1.0, 1.0 + legacyLineSpacing / max(persistedFontSize, 1.0))
        } else {
            lineHeightMultiple = 1.65
        }

        scrollMode = UserDefaults.standard.bool(forKey: "yd_scroll_mode")
        readerBrightness =
            (UserDefaults.standard.object(forKey: "yd_reader_brightness") as? Double) ?? 0.8
        // 預設開啟「跟隨系統亮度」
        if UserDefaults.standard.object(forKey: "yd_follow_sys_brightness") == nil {
            followSystemBrightness = true
        } else {
            followSystemBrightness = UserDefaults.standard.bool(forKey: "yd_follow_sys_brightness")
        }
        letterSpacing =
            (UserDefaults.standard.object(forKey: "yd_letter_spacing") as? Double) ?? 0.0

        if let savedParagraphSpacingMultiplier = UserDefaults.standard.object(forKey: "yd_paragraph_spacing_mult") as? Double {
            paragraphSpacingMultiplier = savedParagraphSpacingMultiplier
        } else if let legacyParagraphSpacing = UserDefaults.standard.object(forKey: "yd_paragraph_spacing") as? Double {
            paragraphSpacingMultiplier = max(0, legacyParagraphSpacing / max(persistedFontSize, 1.0))
        } else {
            paragraphSpacingMultiplier = 0.8
        }

        pageMarginH =
            (UserDefaults.standard.object(forKey: "yd_page_margin_h") as? Double) ?? 24.0
        pageMarginV =
            (UserDefaults.standard.object(forKey: "yd_page_margin_v") as? Double) ?? 16.0
        let rawPageTurn = UserDefaults.standard.string(forKey: "yd_page_turn_style") ?? ""
        pageTurnStyle = PageTurnStyle(rawValue: rawPageTurn) ?? .slide
        let rawWritingMode = UserDefaults.standard.string(forKey: "yd_reader_writing_mode") ?? ""
        readerWritingMode = ReaderWritingMode(rawValue: rawWritingMode) ?? .horizontal
        selectedReaderFontPostScript = UserDefaults.standard.string(forKey: "yd_reader_font_postscript")
        if let fontData = UserDefaults.standard.data(forKey: "yd_user_fonts"),
           let decodedFonts = try? JSONDecoder().decode([UserFontInfo].self, from: fontData) {
            userFonts = decodedFonts
        } else {
            userFonts = []
        }

        searchConcurrency =
            (UserDefaults.standard.object(forKey: "yd_search_concurrency") as? Int) ?? 8
        searchAutoPauseCount =
            (UserDefaults.standard.object(forKey: "yd_search_auto_pause_count") as? Int) ?? 0
        searchCacheDays =
            (UserDefaults.standard.object(forKey: "yd_search_cache_days") as? Int) ?? 5
        useRenderableNodePipeline =
            UserDefaults.standard.bool(forKey: "yd_use_renderable_node_pipeline")
        httpTtsUrlTemplate = UserDefaults.standard.string(forKey: "yd_http_tts_url_template") ?? ""
    }

    @discardableResult
    func importReaderFont(from url: URL) throws -> UserFontInfo {
        let info = try UserFontStorageManager.shared.importFont(fileURL: url)
        userFonts.removeAll { $0.postScriptName == info.postScriptName }
        userFonts.append(info)
        userFonts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        selectedReaderFontPostScript = info.postScriptName
        return info
    }

    func deleteReaderFont(_ font: UserFontInfo) {
        UserFontStorageManager.shared.delete(font)
        userFonts.removeAll { $0.id == font.id }
        if selectedReaderFontPostScript == font.postScriptName {
            selectedReaderFontPostScript = nil
        }
    }
}
