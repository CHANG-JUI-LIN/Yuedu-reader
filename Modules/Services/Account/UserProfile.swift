import YueduCoreText
import Foundation

struct UserProfile: Codable, Equatable {
    var uid: String
    var displayName: String
    var email: String
    var provider: String
    var photoURL: String?
    var createdAt: Date
    var updatedAt: Date
    var preferences: ReaderPreferences

    @MainActor
    init(
        uid: String,
        displayName: String,
        email: String,
        provider: String,
        photoURL: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        preferences: ReaderPreferences = .current()
    ) {
        self.uid = uid
        self.displayName = displayName
        self.email = email
        self.provider = provider
        self.photoURL = photoURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preferences = preferences
    }
}

struct ReaderPreferences: Codable, Equatable {
    var readerFontSize: Double
    var theme: String
    var lineHeightMultiple: Double
    var letterSpacing: Double
    var paragraphSpacingMultiplier: Double
    var pageMarginH: Double
    var pageMarginV: Double
    var pageMarginTop: Double?
    var pageMarginBottom: Double?
    var footerBottomPadding: Double
    var footerTextGap: Double
    var pageTurnStyle: String
    var readerWritingMode: String
    var textConversion: String
    var scrollMode: Bool
    // Header fields arrived later — optional so payloads written by older
    // builds still decode.
    var readerHeaderVisible: Bool?
    var readerHeaderTopPadding: Double?
    var readerHeaderTextGap: Double?
    var readerHeaderFieldPositions: [String: String]?
    /// Per-reading-background 文字顏色 (ReaderTheme raw value → RGB hex).
    var readerTextColorOverrides: [String: UInt32]?

    @MainActor
    static func current(settings: GlobalSettings = .shared) -> ReaderPreferences {
        ReaderPreferences(
            readerFontSize: settings.readerFontSize,
            theme: ReaderTheme.loadPersisted().rawValue,
            lineHeightMultiple: settings.lineHeightMultiple,
            letterSpacing: settings.letterSpacing,
            paragraphSpacingMultiplier: settings.paragraphSpacingMultiplier,
            pageMarginH: settings.pageMarginH,
            pageMarginV: settings.pageMarginV,
            pageMarginTop: settings.pageMarginTop,
            pageMarginBottom: settings.pageMarginBottom,
            footerBottomPadding: settings.footerBottomPadding,
            footerTextGap: settings.footerTextGap,
            pageTurnStyle: settings.pageTurnStyle.rawValue,
            readerWritingMode: settings.readerWritingMode.rawValue,
            textConversion: settings.textConversion.rawValue,
            scrollMode: settings.scrollMode,
            readerHeaderVisible: settings.readerHeaderVisible,
            readerHeaderTopPadding: settings.readerHeaderTopPadding,
            readerHeaderTextGap: settings.readerHeaderTextGap,
            readerHeaderFieldPositions: settings.readerHeaderFieldPositions,
            readerTextColorOverrides: settings.readerTextColorOverrides
        )
    }

    /// What a profile pulled at sign-in — and at every launch that restores the session —
    /// sets here: 簡繁轉換 only.
    ///
    /// The reading setup is not taken from the profile. iCloud syncs it row by row with a
    /// merge clock (`ReadingSettingsSync`), worn through 排版生效範圍; the profile has no
    /// clock and holds whatever was on screen at its last upload — a theme's own values
    /// included. Written here, it overwrote the reader's newer settings on every relaunch
    /// and was recorded into 全域 as an edit, so the next re-wear kept it: FB-166 (11-08,
    /// 行距／段距 back to the theme's after a trip to another app), and feedback #25 and
    /// #22 before it (margins reset on every sign-in). `current()` still uploads the
    /// fields, which the account gateway's schema carries.
    @MainActor
    func apply(to settings: GlobalSettings = .shared) {
        var updates = SettingsUpdateBatch(settings, reason: "readerPreferences")
        defer { updates.finish() }
        updates.set(\.textConversion, TextConversion(rawValue: textConversion) ?? settings.textConversion, field: "textConversion")
    }
}
