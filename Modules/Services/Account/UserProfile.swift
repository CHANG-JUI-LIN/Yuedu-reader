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

    @MainActor
    func apply(to settings: GlobalSettings = .shared) {
        var updates = SettingsUpdateBatch(settings, reason: "readerPreferences")
        defer { updates.finish() }
        updates.set(\.readerFontSize, readerFontSize, field: "readerFontSize")
        if let theme = ReaderTheme(rawValue: theme) {
            if ReaderTheme.loadPersisted() != theme {
                theme.persist()
                settings.adoptReaderDarkMode(from: theme)
            }
        }
        updates.set(\.lineHeightMultiple, lineHeightMultiple, field: "lineHeightMultiple")
        updates.set(\.letterSpacing, letterSpacing, field: "letterSpacing")
        updates.set(\.paragraphSpacingMultiplier, paragraphSpacingMultiplier, field: "paragraphSpacingMultiplier")
        updates.set(\.pageMarginH, pageMarginH, field: "pageMarginH")
        updates.set(\.pageMarginV, pageMarginV, field: "pageMarginV")
        updates.set(\.pageMarginTop, pageMarginTop ?? pageMarginV, field: "pageMarginTop")
        updates.set(\.pageMarginBottom, pageMarginBottom ?? pageMarginV, field: "pageMarginBottom")
        updates.set(\.footerBottomPadding, footerBottomPadding, field: "footerBottomPadding")
        updates.set(\.footerTextGap, footerTextGap, field: "footerTextGap")
        updates.set(\.pageTurnStyle, PageTurnStyle(rawValue: pageTurnStyle) ?? settings.pageTurnStyle, field: "pageTurnStyle")
        updates.set(\.readerWritingMode, ReaderWritingMode(rawValue: readerWritingMode) ?? settings.readerWritingMode, field: "readerWritingMode")
        updates.set(\.textConversion, TextConversion(rawValue: textConversion) ?? settings.textConversion, field: "textConversion")
        updates.set(\.scrollMode, scrollMode, field: "scrollMode")
        if let readerHeaderVisible {
            updates.set(\.readerHeaderVisible, readerHeaderVisible, field: "readerHeaderVisible")
        }
        if let readerHeaderTopPadding {
            updates.set(\.readerHeaderTopPadding, readerHeaderTopPadding, field: "readerHeaderTopPadding")
        }
        if let readerHeaderTextGap {
            updates.set(\.readerHeaderTextGap, readerHeaderTextGap, field: "readerHeaderTextGap")
        }
        if let readerHeaderFieldPositions {
            updates.set(\.readerHeaderFieldPositions, readerHeaderFieldPositions, field: "readerHeaderFieldPositions")
        }
        if let readerTextColorOverrides {
            updates.set(\.readerTextColorOverrides, readerTextColorOverrides, field: "readerTextColorOverrides")
        }
        ReaderConfig.shared.syncFromGlobalSettings()
    }
}
