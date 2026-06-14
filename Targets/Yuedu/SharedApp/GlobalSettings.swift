import Combine
import FirebaseAuth
import Foundation
import GoogleSignIn
import SwiftUI

// MARK: - Reader Text Conversion

enum TextConversion: String, CaseIterable {
    case original = "原文"
    case toTraditional = "繁體"
    case toSimplified = "简体"
}

// MARK: - Page-Turn Style

enum PageTurnStyle: String, CaseIterable {
    case slide = "滑動"
    case cover = "覆蓋翻頁"
    case curl = "仿真翻書"
    case none = "無動畫"
}

// MARK: - Reader Theme

enum ReaderTheme: String, CaseIterable {
    case white = "白天"
    case sepia = "護眼"
    case night = "夜間"

    private static let userDefaultsKey = "yd_reader_theme"
    private static let lastLightThemeKey = "lastLightTheme"
    private static let weChatAccent = UIColor(red: 56 / 255, green: 151 / 255, blue: 241 / 255, alpha: 1)
    private static let weChatDayBackground = UIColor(red: 244 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    private static let weChatNightBackground = UIColor.black
    private static let weChatNightBarBackground = UIColor(red: 26 / 255, green: 26 / 255, blue: 26 / 255, alpha: 1)

    static func loadPersisted() -> ReaderTheme {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return ReaderTheme(rawValue: raw) ?? .white
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
        if self != .night {
            UserDefaults.standard.set(rawValue, forKey: Self.lastLightThemeKey)
        }
    }

    var backgroundColor: Color {
        Color(uiColor: uiBackgroundColor)
    }

    var textColor: Color {
        Color(uiColor: uiTextColor)
    }

    var accentColor: Color {
        Color(uiColor: uiAccentColor)
    }

    var uiBackgroundColor: UIColor {
        switch self {
        case .white: return Self.weChatDayBackground
        case .sepia: return UIColor(red: 244 / 255, green: 236 / 255, blue: 216 / 255, alpha: 1)
        case .night: return Self.weChatNightBackground
        }
    }

    var uiTextColor: UIColor {
        switch self {
        case .white: return UIColor(red: 51 / 255, green: 51 / 255, blue: 51 / 255, alpha: 1)
        case .sepia: return UIColor(red: 91 / 255, green: 70 / 255, blue: 54 / 255, alpha: 1)
        case .night: return UIColor(red: 217 / 255, green: 217 / 255, blue: 217 / 255, alpha: 1)
        }
    }

    var uiAccentColor: UIColor {
        Self.weChatAccent
    }

    var barColor: Color {
        Color(uiColor: uiBarColor)
    }

    var uiBarColor: UIColor {
        switch self {
        case .white: return .white
        case .sepia: return UIColor(red: 0.93, green: 0.91, blue: 0.83, alpha: 1)
        case .night: return Self.weChatNightBarBackground
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
    @Published var footerBottomPadding: CGFloat
    @Published var footerTextGap: CGFloat
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
        footerBottomPadding = CGFloat(gs.footerBottomPadding)
        footerTextGap = CGFloat(gs.footerTextGap)
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
        footerBottomPadding = CGFloat(gs.footerBottomPadding)
        footerTextGap = CGFloat(gs.footerTextGap)
        theme = ReaderTheme.loadPersisted()
        suppressRefresh = false
    }

    private func setupBindings() {
        let layoutPublisher = Publishers.CombineLatest4($fontSize, $lineHeightMultiple, $letterSpacing, $paragraphSpacingMultiplier)
            .combineLatest($pageMarginH, $pageMarginV)
            .combineLatest($footerBottomPadding, $footerTextGap)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)

        layoutPublisher
            .dropFirst()
            .sink { [weak self] layout, footerBottomPadding, footerTextGap in
                guard let self else { return }
                let (combined, marginH, marginV) = layout
                let (fontSize, lineHeightMultiple, letterSpacing, paragraphSpacingMultiplier) = combined
                let gs = GlobalSettings.shared
                gs.readerFontSize = Double(fontSize)
                gs.lineHeightMultiple = Double(lineHeightMultiple)
                gs.letterSpacing = Double(letterSpacing)
                gs.paragraphSpacingMultiplier = Double(paragraphSpacingMultiplier)
                gs.pageMarginH = Double(marginH)
                gs.pageMarginV = Double(marginV)
                gs.footerBottomPadding = Double(footerBottomPadding)
                gs.footerTextGap = Double(footerTextGap)
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
    /// Offline ICU text conversion for book content.
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

// MARK: - Global Settings

class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()

    // MARK: - Account State

    @Published var isLoggedIn: Bool {
        didSet { UserDefaults.standard.set(isLoggedIn, forKey: "yd_account_logged_in") }
    }
    @Published var accountDisplayName: String {
        didSet { UserDefaults.standard.set(accountDisplayName, forKey: "yd_account_display_name") }
    }
    @Published var accountEmail: String {
        didSet { UserDefaults.standard.set(accountEmail, forKey: "yd_account_email") }
    }
    @Published var accountProvider: String {
        didSet { UserDefaults.standard.set(accountProvider, forKey: "yd_account_provider") }
    }
    @Published var accountUserIdentifier: String {
        didSet { UserDefaults.standard.set(accountUserIdentifier, forKey: "yd_account_user_identifier") }
    }
    @Published var accountPhotoURL: String {
        didSet { UserDefaults.standard.set(accountPhotoURL, forKey: "yd_account_photo_url") }
    }

    /// Subtitle shown under the account name. Prefers a real email, otherwise falls
    /// back to a provider description so we never display an opaque identifier.
    var accountSubtitle: String {
        guard isLoggedIn else { return localized("登入後可同步進度") }
        if !accountEmail.isEmpty { return accountEmail }
        switch accountProvider {
        case "Apple": return localized("透過 Apple 登入")
        case "Google": return localized("透過 Google 登入")
        default: return localized("已登入")
        }
    }
    @Published var accountAvatarData: Data? {
        didSet {
            if let accountAvatarData {
                UserDefaults.standard.set(accountAvatarData, forKey: "yd_account_avatar_data")
            } else {
                UserDefaults.standard.removeObject(forKey: "yd_account_avatar_data")
            }
        }
    }

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
    @Published var footerBottomPadding: Double {
        didSet { UserDefaults.standard.set(footerBottomPadding, forKey: "yd_footer_bottom_padding") }
    }
    @Published var footerTextGap: Double {
        didSet { UserDefaults.standard.set(footerTextGap, forKey: "yd_footer_text_gap") }
    }
    @Published var pageTurnStyle: PageTurnStyle {
        didSet { UserDefaults.standard.set(pageTurnStyle.rawValue, forKey: "yd_page_turn_style") }
    }
    @Published var readerSpreadMode: ReaderSpreadMode {
        didSet { UserDefaults.standard.set(readerSpreadMode.rawValue, forKey: "yd_reader_spread_mode") }
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

    // MARK: - Reader Font (persisted across sessions)

    @Published var readerFontSize: Double {
        didSet { UserDefaults.standard.set(readerFontSize, forKey: "yd_reader_font_size") }
    }

    /// Additional inter-line spacing derived from the line-height multiplier (pt).
    var lineSpacing: Double {
        max(0, (lineHeightMultiple - 1.0) * readerFontSize)
    }

    /// Paragraph spacing derived from the multiplier (pt).
    var paragraphSpacing: Double {
        max(0, readerFontSize * paragraphSpacingMultiplier)
    }

    var localeIdentifier: String {
        Locale.autoupdatingCurrent.identifier
    }

    // MARK: - Network Settings

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

    /// Auto iCloud sync: merge with iCloud on launch and when backgrounding.
    @Published var iCloudAutoSync: Bool {
        didSet { UserDefaults.standard.set(iCloudAutoSync, forKey: "yd_icloud_auto_sync") }
    }

    // MARK: - TTS Settings

    @Published var httpTtsUrlTemplate: String {
        didSet { UserDefaults.standard.set(httpTtsUrlTemplate, forKey: "yd_http_tts_url_template") }
    }
    @Published var httpTtsHeaders: [String: String] {
        didSet { Self.saveTTSHeaders(httpTtsHeaders) }
    }
    @Published var importedTTSSources: [ImportedTTSSource] {
        didSet { Self.saveImportedTTSSources(importedTTSSources) }
    }
    /// Force the offline, on-device `AVSpeechSynthesizer` voice even when an HTTP source exists.
    @Published var ttsUseSystemVoice: Bool {
        didSet { UserDefaults.standard.set(ttsUseSystemVoice, forKey: "yd_tts_use_system_voice") }
    }
    /// Selected `AVSpeechSynthesisVoice` identifier for the offline engine; empty = auto by language.
    @Published var ttsSystemVoiceIdentifier: String {
        didSet { UserDefaults.standard.set(ttsSystemVoiceIdentifier, forKey: "yd_tts_system_voice_id") }
    }

    private init() {
        UserDefaults.standard.removeObject(forKey: "yd_app_lang")
        isLoggedIn = UserDefaults.standard.bool(forKey: "yd_account_logged_in")
        accountDisplayName = UserDefaults.standard.string(forKey: "yd_account_display_name") ?? ""
        accountEmail = UserDefaults.standard.string(forKey: "yd_account_email") ?? ""
        accountProvider = UserDefaults.standard.string(forKey: "yd_account_provider") ?? ""
        accountUserIdentifier = UserDefaults.standard.string(forKey: "yd_account_user_identifier") ?? ""
        accountPhotoURL = UserDefaults.standard.string(forKey: "yd_account_photo_url") ?? ""
        accountAvatarData = UserDefaults.standard.data(forKey: "yd_account_avatar_data")
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
        footerBottomPadding =
            (UserDefaults.standard.object(forKey: "yd_footer_bottom_padding") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultFooterBottomPadding)
        footerTextGap =
            (UserDefaults.standard.object(forKey: "yd_footer_text_gap") as? Double)
            ?? Double(ReaderLayoutMetrics.defaultFooterTextGap)
        let rawPageTurn = UserDefaults.standard.string(forKey: "yd_page_turn_style") ?? ""
        pageTurnStyle = PageTurnStyle(rawValue: rawPageTurn) ?? .slide
        let rawSpreadMode = UserDefaults.standard.string(forKey: "yd_reader_spread_mode") ?? ""
        let loadedSpreadMode = (ReaderSpreadMode(rawValue: rawSpreadMode) ?? .singlePage).normalizedForUserSelection
        readerSpreadMode = loadedSpreadMode
        if rawSpreadMode != loadedSpreadMode.rawValue {
            UserDefaults.standard.set(loadedSpreadMode.rawValue, forKey: "yd_reader_spread_mode")
        }
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
        iCloudAutoSync =
            (UserDefaults.standard.object(forKey: "yd_icloud_auto_sync") as? Bool) ?? true
        httpTtsUrlTemplate = UserDefaults.standard.string(forKey: "yd_http_tts_url_template") ?? ""
        httpTtsHeaders = Self.loadTTSHeaders()
        importedTTSSources = Self.loadImportedTTSSources()
        ttsUseSystemVoice = UserDefaults.standard.bool(forKey: "yd_tts_use_system_voice")
        ttsSystemVoiceIdentifier = UserDefaults.standard.string(forKey: "yd_tts_system_voice_id") ?? ""
    }

    private static func loadImportedTTSSources() -> [ImportedTTSSource] {
        guard let data = UserDefaults.standard.data(forKey: "yd_imported_tts_sources"),
              let decoded = try? JSONDecoder().decode([ImportedTTSSource].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveImportedTTSSources(_ sources: [ImportedTTSSource]) {
        if sources.isEmpty {
            UserDefaults.standard.removeObject(forKey: "yd_imported_tts_sources")
            return
        }
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: "yd_imported_tts_sources")
        }
    }

    private static func loadTTSHeaders() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "yd_http_tts_headers"),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveTTSHeaders(_ headers: [String: String]) {
        if headers.isEmpty {
            UserDefaults.standard.removeObject(forKey: "yd_http_tts_headers")
            return
        }
        if let data = try? JSONEncoder().encode(headers) {
            UserDefaults.standard.set(data, forKey: "yd_http_tts_headers")
        }
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

    func signIn(displayName: String, email: String, provider: String, userIdentifier: String = "") {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdentifier = userIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        accountDisplayName = trimmedName.isEmpty ? trimmedEmail : trimmedName
        accountEmail = trimmedEmail
        accountProvider = provider
        accountUserIdentifier = trimmedIdentifier
        isLoggedIn = true
    }

    @MainActor
    func applyFirebaseUser(_ user: User?, providerOverride: String? = nil) {
        guard let user else {
            clearAccountState()
            return
        }

        let email = user.email ?? ""
        let displayName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        accountDisplayName = displayName?.isEmpty == false ? displayName! : (email.isEmpty ? localized("已登入") : email)
        accountEmail = email
        accountProvider = providerOverride ?? Self.providerDisplayName(from: user)
        accountUserIdentifier = user.uid
        accountPhotoURL = user.photoURL?.absoluteString ?? accountPhotoURL
        isLoggedIn = true
    }

    @MainActor
    func applyFirebaseProfile(_ profile: UserProfile) {
        accountDisplayName = profile.displayName
        accountEmail = profile.email
        accountProvider = profile.provider
        accountUserIdentifier = profile.uid
        accountPhotoURL = profile.photoURL ?? ""
        isLoggedIn = true
        profile.preferences.apply(to: self)
    }

    func updateAccountAvatar(data: Data?) {
        accountAvatarData = data
    }

    func updateAccountDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accountDisplayName = trimmed
    }

    func signOut(
        revokeGoogleAccess: Bool = false,
        completion: ((Error?) -> Void)? = nil
    ) {
        let provider = accountProvider

        guard provider == "Google" else {
            clearAccountState()
            completion?(nil)
            return
        }

        if revokeGoogleAccess {
            GIDSignIn.sharedInstance.disconnect { [weak self] error in
                if error != nil {
                    GIDSignIn.sharedInstance.signOut()
                }
                DispatchQueue.main.async {
                    self?.clearAccountState()
                    completion?(error)
                }
            }
            return
        }

        GIDSignIn.sharedInstance.signOut()
        clearAccountState()
        completion?(nil)
    }

    func clearAccountState() {
        isLoggedIn = false
        accountDisplayName = ""
        accountEmail = ""
        accountProvider = ""
        accountUserIdentifier = ""
        accountPhotoURL = ""
        accountAvatarData = nil
    }

    private static func providerDisplayName(from user: User) -> String {
        switch user.providerData.first?.providerID {
        case "google.com":
            return "Google"
        case "apple.com":
            return "Apple"
        case "password":
            return "Email"
        default:
            return user.providerData.first?.providerID ?? "Firebase"
        }
    }
}
