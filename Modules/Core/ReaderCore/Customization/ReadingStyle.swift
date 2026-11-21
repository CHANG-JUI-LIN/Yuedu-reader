import Foundation
import YueduCoreText

/// 閱讀樣式 the reader saved: a whole reading setup under a name, worn again with one tap.
///
/// What it holds is exactly what a theme can hold (`AppearanceThemeReadingSettings`):
/// typesetting and the page's look. Brightness, 繁簡轉換, gestures and tap zones are how
/// the reader behaves, and a style changing them would read as a malfunction.
struct ReadingStyle: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Every row filled in, with no row on 自動: the numbers that were on screen.
    var values: AppearanceThemeReadingSettings

    init(id: String = "custom." + UUID().uuidString, name: String, values: AppearanceThemeReadingSettings) {
        self.id = id
        self.name = name
        self.values = values
    }
}

/// A reading style that ships with the app. Sparse: the rows it does not name stay as
/// they are — the page's decorations, the header and footer — or go back to the book's
/// 排版基準 when they are typesetting.
struct BuiltInReadingStyle: Identifiable, Equatable, Sendable {
    /// The interface language whose readers the style is drawn up for. Every style is
    /// offered in every language; this only decides which come first.
    enum Language: String, CaseIterable, Sendable {
        case traditionalChinese = "zh-Hant"
        case simplifiedChinese = "zh-Hans"
        case japanese = "ja"
        case korean = "ko"
        case english = "en"

        var titleKey: String {
            switch self {
            case .traditionalChinese: return "ReadingStyle.Language.zhHant"
            case .simplifiedChinese: return "ReadingStyle.Language.zhHans"
            case .japanese: return "ReadingStyle.Language.ja"
            case .korean: return "ReadingStyle.Language.ko"
            case .english: return "ReadingStyle.Language.en"
            }
        }

        /// The interface language, or Traditional Chinese — the development language —
        /// for one the app is not localized in.
        static var interface: Language {
            let code = Bundle.main.preferredLocalizations.first ?? ""
            return allCases.first { code.hasPrefix($0.rawValue) } ?? .traditionalChinese
        }
    }

    let id: String
    let nameKey: String
    let language: Language
    /// PostScript name of the face, or `""` for the default one.
    let font: String
    /// The system font family `CJKFontInstaller` fetches when `font` is not on the
    /// device yet; nil for a face every device has.
    let downloadableFamily: String?
    private let layout: AppearanceThemeReadingSettings

    init(
        id: String, nameKey: String, language: Language, font: String = "",
        downloadableFamily: String? = nil,
        fontSize: Double, lineHeight: Double, paragraphSpacing: Double, indent: Double,
        alignment: ReaderBodyTextAlignment = .justified,
        marginH: Double, marginV: Double,
        vertical: Bool = false, background: ReaderTheme? = nil
    ) {
        self.id = id
        self.nameKey = nameKey
        self.language = language
        self.font = font
        self.downloadableFamily = downloadableFamily
        var reading = AppearanceThemeReadingSettings()
        reading.fontPostScript = font
        reading.fontSize = fontSize
        reading.isBold = false
        reading.lineHeightMultiple = lineHeight
        reading.letterSpacing = 0
        reading.paragraphSpacingMultiplier = paragraphSpacing
        reading.firstLineIndent = indent
        reading.textAlignment = alignment.rawValue
        reading.setMargins(horizontal: marginH, vertical: marginV)
        reading.writingMode = (vertical ? ReaderWritingMode.verticalRTL : .horizontal).rawValue
        reading.readerTheme = background?.rawValue
        layout = reading
    }

    /// The style's rows. One set for every 排版基準 today; the parameter is where a style
    /// that should differ by the book's language gets to.
    func values(for baseline: ReadingBaseline) -> AppearanceThemeReadingSettings {
        layout
    }
}

/// The reading styles that ship with the app: two for each interface language, drawn
/// up from that language's typesetting conventions (W3C clreq, jlreq, klreq; Latin book
/// typography). See Technotes/ReadingStyles-2026-10-07-design.md §13.
enum ReadingStyleLibrary {
    static let builtIns: [BuiltInReadingStyle] = [
        // 繁體中文: a literary book set vertically in Ming type, and an airy horizontal page.
        BuiltInReadingStyle(
            id: "builtin.zhHant.book", nameKey: "ReadingStyle.zhHant.book", language: .traditionalChinese,
            font: "STSongti-TC-Regular", downloadableFamily: "Songti TC",
            fontSize: 19, lineHeight: 1.8, paragraphSpacing: 0.4, indent: 2,
            marginH: 28, marginV: 24, vertical: true, background: .sepia),
        BuiltInReadingStyle(
            id: "builtin.zhHant.airy", nameKey: "ReadingStyle.zhHant.airy", language: .traditionalChinese,
            fontSize: 18, lineHeight: 1.8, paragraphSpacing: 0.9, indent: 2,
            marginH: 26, marginV: 18, background: .white),
        // 简体中文: the dense page of a web-novel app, and a printed book in Song type.
        BuiltInReadingStyle(
            id: "builtin.zhHans.web", nameKey: "ReadingStyle.zhHans.web", language: .simplifiedChinese,
            fontSize: 17, lineHeight: 1.5, paragraphSpacing: 0.5, indent: 2,
            marginH: 18, marginV: 12, background: .green),
        BuiltInReadingStyle(
            id: "builtin.zhHans.print", nameKey: "ReadingStyle.zhHans.print", language: .simplifiedChinese,
            font: "STSongti-SC-Regular", downloadableFamily: "Songti SC",
            fontSize: 18, lineHeight: 1.7, paragraphSpacing: 0.6, indent: 2,
            marginH: 28, marginV: 20, background: .white),
        // 日本語: a bunko paperback — vertical Mincho, one-character indent, no gap
        // between paragraphs — and its horizontal counterpart.
        BuiltInReadingStyle(
            id: "builtin.ja.bunko", nameKey: "ReadingStyle.ja.bunko", language: .japanese,
            font: "HiraMinProN-W3",
            fontSize: 17, lineHeight: 1.8, paragraphSpacing: 0.3, indent: 1,
            marginH: 24, marginV: 28, vertical: true, background: .sepia),
        BuiltInReadingStyle(
            id: "builtin.ja.yoko", nameKey: "ReadingStyle.ja.yoko", language: .japanese,
            fontSize: 16, lineHeight: 1.8, paragraphSpacing: 0.5, indent: 1,
            marginH: 24, marginV: 16, background: .white),
        // 한국어: a printed book in Myungjo, and the ragged, widely spaced web novel.
        BuiltInReadingStyle(
            id: "builtin.ko.book", nameKey: "ReadingStyle.ko.book", language: .korean,
            // No Korean serif ships with iOS; Myungjo is one of the faces it fetches on demand.
            font: "AppleMyungjo", downloadableFamily: "AppleMyungjo",
            fontSize: 17, lineHeight: 1.75, paragraphSpacing: 0.4, indent: 1,
            marginH: 26, marginV: 18, background: .white),
        BuiltInReadingStyle(
            id: "builtin.ko.web", nameKey: "ReadingStyle.ko.web", language: .korean,
            fontSize: 17, lineHeight: 1.7, paragraphSpacing: 1.0, indent: 0, alignment: .start,
            marginH: 20, marginV: 16, background: .white),
        // English: a paperback — serif, indented, justified — and a spaced sans page.
        BuiltInReadingStyle(
            id: "builtin.en.paperback", nameKey: "ReadingStyle.en.paperback", language: .english,
            font: "Georgia",
            fontSize: 18, lineHeight: 1.4, paragraphSpacing: 0.3, indent: 1.5,
            marginH: 30, marginV: 20, background: .sepia),
        BuiltInReadingStyle(
            id: "builtin.en.modern", nameKey: "ReadingStyle.en.modern", language: .english,
            fontSize: 17, lineHeight: 1.5, paragraphSpacing: 0.9, indent: 0, alignment: .start,
            marginH: 24, marginV: 16, background: .white),
    ]

    static func builtIn(id: String) -> BuiltInReadingStyle? {
        builtIns.first { $0.id == id }
    }

    /// Every built-in style, the interface language's first; the rest keep their order.
    static func ordered(for language: BuiltInReadingStyle.Language = .interface) -> [BuiltInReadingStyle] {
        builtIns.filter { $0.language == language } + builtIns.filter { $0.language != language }
    }
}
