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

    static func current(settings: GlobalSettings = .shared) -> ReaderPreferences {
        ReaderPreferences(
            readerFontSize: settings.readerFontSize,
            theme: ReaderTheme.loadPersisted().rawValue,
            lineHeightMultiple: settings.lineHeightMultiple,
            letterSpacing: settings.letterSpacing,
            paragraphSpacingMultiplier: settings.paragraphSpacingMultiplier,
            pageMarginH: settings.pageMarginH,
            pageMarginV: settings.pageMarginV,
            footerBottomPadding: settings.footerBottomPadding,
            footerTextGap: settings.footerTextGap,
            pageTurnStyle: settings.pageTurnStyle.rawValue,
            readerWritingMode: settings.readerWritingMode.rawValue,
            textConversion: settings.textConversion.rawValue,
            scrollMode: settings.scrollMode,
            readerHeaderVisible: settings.readerHeaderVisible,
            readerHeaderTopPadding: settings.readerHeaderTopPadding,
            readerHeaderTextGap: settings.readerHeaderTextGap,
            readerHeaderFieldPositions: settings.readerHeaderFieldPositions
        )
    }

    @MainActor
    func apply(to settings: GlobalSettings = .shared) {
        settings.readerFontSize = readerFontSize
        if let theme = ReaderTheme(rawValue: theme) {
            theme.persist()
            ReaderConfig.shared.theme = theme
        }
        settings.lineHeightMultiple = lineHeightMultiple
        settings.letterSpacing = letterSpacing
        settings.paragraphSpacingMultiplier = paragraphSpacingMultiplier
        settings.pageMarginH = pageMarginH
        settings.pageMarginV = pageMarginV
        settings.footerBottomPadding = footerBottomPadding
        settings.footerTextGap = footerTextGap
        settings.pageTurnStyle = PageTurnStyle(rawValue: pageTurnStyle) ?? settings.pageTurnStyle
        settings.readerWritingMode = ReaderWritingMode(rawValue: readerWritingMode) ?? settings.readerWritingMode
        settings.textConversion = TextConversion(rawValue: textConversion) ?? settings.textConversion
        settings.scrollMode = scrollMode
        if let readerHeaderVisible {
            settings.readerHeaderVisible = readerHeaderVisible
        }
        if let readerHeaderTopPadding {
            settings.readerHeaderTopPadding = readerHeaderTopPadding
        }
        if let readerHeaderTextGap {
            settings.readerHeaderTextGap = readerHeaderTextGap
        }
        if let readerHeaderFieldPositions {
            settings.readerHeaderFieldPositions = readerHeaderFieldPositions
        }
        ReaderConfig.shared.syncFromGlobalSettings()
    }
}
