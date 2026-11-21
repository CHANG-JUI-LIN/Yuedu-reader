import Foundation
import Testing
import UIKit
import YueduCoreText
import YueduCoreTextTypography
@testable import yuedu_app

/// 自動, 排版基準 and 閱讀樣式 (2026-11-21): a row left on 自動 is set from the book's baseline
/// and the worn style; one with numbers of its own keeps them. A style is applied
/// through the one writer of reading settings and adds no store of its own.
@Suite("閱讀樣式", .serialized)
@MainActor
struct ReadingStyleTests {
    // MARK: - The model

    @Test func automaticRowsMergeAndClearRowByRow() {
        var base = AppearanceThemeReadingSettings()
        base.automaticItems = ["fontSize": true, "lineSpacing": true]
        var edit = AppearanceThemeReadingSettings()
        edit.automaticItems = ["fontSize": false]

        let merged = base.overlaid(with: edit)
        #expect(merged.automaticItems == ["fontSize": false, "lineSpacing": true])
        // A row's flag is the row's: an edit of one is an edit of that row alone.
        #expect(edit.items == [.fontSize])
        #expect(merged.restricted(to: [.lineSpacing]).automaticItems == ["lineSpacing": true])
        #expect(merged.restricted(to: [.pageMargins]).isEmpty)
    }

    /// A pack, a `.qitheme`, a backup or another device's row from before 自動 carries
    /// numbers and no flag. It means the numbers.
    @Test func valuesWithNoWordAboutAutomaticAreExplicit() {
        var pack = AppearanceThemeReadingSettings()
        pack.fontSize = 24
        pack.scrollMode = true
        let implied = pack.withImpliedExplicitRows()
        #expect(implied.automaticItems == ["fontSize": false])

        var automatic = AppearanceThemeReadingSettings()
        automatic.fontSize = 24
        automatic.automaticItems = ["fontSize": true]
        #expect(automatic.withImpliedExplicitRows().automaticItems == ["fontSize": true])
    }

    @Test func everyBaselineAndStyleStaysInsideTheSliders() {
        var all = ReadingBaseline.allCases.map(\.values)
        all += ReadingStyleLibrary.builtIns.map { $0.values(for: .chinese) }
        for reading in all {
            #expect(GlobalSettings.readerFontSizeRange.contains(reading.fontSize ?? 18))
            #expect((1.0...2.4).contains(reading.lineHeightMultiple ?? 1.6))
            #expect((0.3...1.2).contains(reading.paragraphSpacingMultiplier ?? 0.8))
            #expect(ReaderFirstLineIndent.range.contains(reading.firstLineIndent ?? 2))
            #expect((0...ReaderReadableWidthPolicy.compactUpperBound).contains(reading.pageMarginH ?? 24))
            #expect(ReaderVerticalMargin.range.contains(reading.pageMarginTop ?? 16))
            #expect(ReaderBodyTextAlignment(rawValue: reading.textAlignment ?? "justified") != nil)
        }
        // Every row a baseline speaks for is filled in, so a row on 自動 is never unset.
        for baseline in ReadingBaseline.allCases {
            #expect(baseline.values.items == ReadingBaseline.items)
        }
    }

    /// A Chinese book on 自動 is set exactly as every book was before baselines.
    @Test func theChineseBaselineIsTheOldDefaults() {
        let chinese = ReadingBaseline.chinese.values
        #expect(chinese.fontSize == GlobalSettings.defaultReaderFontSize)
        #expect(chinese.lineHeightMultiple == GlobalSettings.defaultReaderLineHeightMultiple)
        #expect(chinese.paragraphSpacingMultiplier == GlobalSettings.defaultReaderParagraphSpacingMultiplier)
        #expect(chinese.pageMarginH == GlobalSettings.defaultReaderPageMarginH)
        #expect(chinese.pageMarginTop == GlobalSettings.defaultReaderPageMarginV)
        #expect(chinese.firstLineIndent == ReaderFirstLineIndent.default)
        #expect(chinese.fontPostScript == "")
    }

    /// A face a style names and the device does not have falls back to the default one
    /// without a word, so the ones every device ships with are checked here. The Songti
    /// faces are fetched on demand (`downloadableFamily`) and are not.
    @Test func theFacesStylesNameAreOnTheDevice() {
        for style in ReadingStyleLibrary.builtIns where !style.font.isEmpty && style.downloadableFamily == nil {
            #expect(UIFont(name: style.font, size: 17) != nil, "\(style.id): \(style.font)")
        }
        #expect(Set(ReadingStyleLibrary.builtIns.map(\.id)).count == ReadingStyleLibrary.builtIns.count)
        for language in BuiltInReadingStyle.Language.allCases {
            #expect(ReadingStyleLibrary.builtIns.filter { $0.language == language }.count == 2)
            #expect(ReadingStyleLibrary.ordered(for: language).first?.language == language)
        }
    }

    @Test func aBooksBaselineFollowsItsText() {
        #expect(ReadingBaseline.resolve(sample: "The Old Man and the Sea\nChapter 1", decided: nil, isVertical: false) == .english)
        #expect(ReadingBaseline.resolve(sample: "吾輩は猫である\nわがはいはねこである", decided: nil, isVertical: true) == .japaneseVertical)
        #expect(ReadingBaseline.resolve(sample: "吾輩は猫である\nわがはいはねこである", decided: nil, isVertical: false) == .japaneseHorizontal)
        #expect(ReadingBaseline.resolve(sample: "채식주의자\n한강 지음 장편소설", decided: nil, isVertical: false) == .korean)
        #expect(ReadingBaseline.resolve(sample: "紅樓夢\n第一回 甄士隱夢幻識通靈。賈雨村風塵懷閨秀。", decided: nil, isVertical: false) == .chinese)
        // What the book's chapters already decided wins over a title that says otherwise.
        #expect(ReadingBaseline.resolve(sample: "Chapter 1", decided: .japanese, isVertical: true) == .japaneseVertical)
    }

    // MARK: - 自動

    /// The acceptance of the whole change for an upgrade: every row keeps its numbers,
    /// whatever book is opened.
    @Test func anUpgradedSetupKeepsItsNumbersForEveryBook() {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        settings.readerFontSize = 22
        settings.lineHeightMultiple = 2.0

        for baseline in ReadingBaseline.allCases {
            settings.setReadingBaseline(baseline)
            settings.synchronizeReadingSettings()
            #expect(settings.readerFontSize == 22)
            #expect(settings.lineHeightMultiple == 2.0)
            #expect(settings.readerFirstLineIndent == 2)
        }
    }

    @Test func aRowOnAutomaticFollowsTheBook() {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared

        settings.setReadingBaseline(.chinese)
        settings.setReadingRowAutomatic(.lineSpacing, true)
        settings.setReadingRowAutomatic(.firstLineIndent, true)
        #expect(settings.lineHeightMultiple == 1.65)

        settings.setReadingBaseline(.english)
        #expect(settings.lineHeightMultiple == 1.45)
        #expect(settings.readerFirstLineIndent == 0)
        // The reload the writer triggers is not an edit: the rows are still on 自動, and
        // the mirror shows what was written.
        #expect(settings.readerAutomaticItems == [.lineSpacing, .firstLineIndent])
        #expect(ReaderConfig.shared.lineHeightMultiple == 1.45)
        // A row with numbers of its own does not move.
        #expect(settings.readerFontSize == 18)

        settings.setReadingBaseline(.japaneseVertical)
        #expect(settings.lineHeightMultiple == 1.75)
        #expect(settings.readerFirstLineIndent == 1)
    }

    /// The edited value, and the rest of its row as shown — not the fields the row
    /// had stored before it was left to 自動.
    @Test func anEditTakesItsRowOffAutomaticWithWhatItShowed() {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        settings.pageMarginH = 40
        settings.pageMarginTop = 50
        settings.pageMarginBottom = 50

        settings.setReadingBaseline(.english)
        settings.setReadingRowAutomatic(.pageMargins, true)
        #expect(settings.pageMarginH == 28)
        #expect(settings.pageMarginTop == 16)

        settings.pageMarginH = 30
        #expect(!settings.readerAutomaticItems.contains(.pageMargins))
        settings.synchronizeReadingSettings()
        #expect(settings.pageMarginH == 30)
        #expect(settings.pageMarginTop == 16)
        #expect(settings.pageMarginBottom == 16)

        // And it stays put for another kind of book.
        settings.setReadingBaseline(.chinese)
        #expect(settings.pageMarginH == 30)
    }

    @Test func takingARowOffAutomaticKeepsWhatItShows() {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        settings.setReadingBaseline(.korean)
        settings.setReadingRowAutomatic(.fontSize, true)
        #expect(settings.readerFontSize == 17)

        settings.setReadingRowAutomatic(.fontSize, false)
        settings.setReadingBaseline(.chinese)
        #expect(settings.readerFontSize == 17)
    }

    /// A pack's own numbers are worn with the pack even when the shared setup leaves
    /// the row on 自動.
    @Test func aThemesOwnNumbersWinOverAutomatic() {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        settings.setReadingBaseline(.english)
        settings.setReadingRowAutomatic(.fontSize, true)
        settings.setReadingRowAutomatic(.lineSpacing, true)
        fixture.forgetThemeEdits()

        var reading = AppearanceThemeReadingSettings()
        reading.fontSize = 24
        var extras = AppearanceThemeExtras()
        extras.reading = reading
        let pack = AppearanceCustomTheme(name: "Pack", backgroundHex: 0xFFFFFF, textHex: 0,
                                         barHex: 0xFFFFFF, accentHex: 0x123456, dialogueHex: 0, extras: extras)
        settings.customAppearanceThemes.append(pack)
        fixture.imported.append(pack.id)

        settings.appearanceThemeID = pack.id
        #expect(settings.readerFontSize == 24)
        // The row the pack says nothing about is still the book's.
        #expect(settings.lineHeightMultiple == 1.45)

        settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
        #expect(settings.readerFontSize == 18)
    }

    // MARK: - 閱讀樣式

    @Test func aBuiltInStyleIsWornOverTheBaseline() throws {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        settings.setReadingBaseline(.english)
        let style = try #require(ReadingStyleLibrary.builtIn(id: "builtin.en.paperback"))

        try settings.applyReadingStyle(style)
        #expect(settings.readerReadingStyleID == style.id)
        #expect(settings.appliedReadingStyleName != nil)
        #expect(settings.selectedReaderFontPostScript == "Georgia")
        #expect(settings.readerFontSize == 18)
        #expect(settings.lineHeightMultiple == 1.4)
        #expect(settings.readerFirstLineIndent == 1.5)
        #expect(settings.pageMarginH == 30)
        #expect(ReaderTheme.loadPersisted() == .sepia)
        #expect(settings.readerAutomaticItems == ReadingBaseline.items)
        #expect(!settings.isReadingStyleModified)
        // Worn again — a theme switch, a relaunch — it is the same page.
        settings.synchronizeReadingSettings()
        #expect(settings.lineHeightMultiple == 1.4)

        settings.lineHeightMultiple = 1.6
        #expect(settings.isReadingStyleModified)
        #expect(settings.readerFontSize == 18)

        try settings.applyReadingStyle(style)
        #expect(settings.lineHeightMultiple == 1.4)
        #expect(!settings.isReadingStyleModified)
    }

    /// The report (2026-11-21): once a style was applied there was no way back to the
    /// page before it. 未套用 puts back what the style's rows showed — after one style or
    /// several — and leaves alone what the style never touched.
    @Test func removingAStylePutsBackThePageBeforeIt() throws {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        defer { UserDefaults.standard.removeObject(forKey: GlobalSettings.setupBeforeReadingStyleKey) }
        let settings = GlobalSettings.shared
        settings.readerFontSize = 22
        settings.lineHeightMultiple = 2.0
        settings.pageMarginH = 12

        try settings.applyReadingStyle(try #require(ReadingStyleLibrary.builtIn(id: "builtin.ja.bunko")))
        try settings.applyReadingStyle(try #require(ReadingStyleLibrary.builtIn(id: "builtin.en.paperback")))
        #expect(settings.readerFontSize == 18)
        // Changed while the style is on, and not one of its rows.
        settings.scrollMode = true

        try settings.removeReadingStyle()
        #expect(settings.readerReadingStyleID == nil)
        #expect(settings.readerFontSize == 22)
        #expect(settings.lineHeightMultiple == 2.0)
        #expect(settings.pageMarginH == 12)
        #expect(settings.selectedReaderFontPostScript == nil)
        #expect(settings.readerWritingMode == .horizontal)
        #expect(settings.readerAutomaticItems.isEmpty)
        #expect(settings.scrollMode)
        // And it holds: the rows are the reader's own numbers again.
        settings.synchronizeReadingSettings()
        #expect(settings.readerFontSize == 22)

        // Nothing applied: nothing to take off.
        try settings.removeReadingStyle()
        #expect(settings.readerFontSize == 22)
    }

    @Test func aVerticalStyleTurnsThePage() throws {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        let bunko = try #require(ReadingStyleLibrary.builtIn(id: "builtin.ja.bunko"))
        try settings.applyReadingStyle(bunko)
        #expect(settings.readerWritingMode == .verticalRTL)
        #expect(settings.selectedReaderFontPostScript == "HiraMinProN-W3")
        #expect(!settings.isReadingStyleModified)

        settings.readerWritingMode = .horizontal
        #expect(settings.isReadingStyleModified)
    }

    @Test func aSavedStyleIsTheNumbersOnScreen() throws {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        settings.setReadingBaseline(.english)
        // Some rows on 自動 when it is saved: the style keeps what they showed.
        settings.setReadingRowAutomatic(.lineSpacing, true)
        settings.readerFontSize = 21
        settings.scrollMode = true

        let saved = settings.saveCurrentReadingSetupAsStyle(named: "夜讀")
        #expect(settings.customReadingStyles.contains { $0.id == saved.id })
        #expect(settings.readerReadingStyleID == saved.id)
        #expect(settings.appliedReadingStyleName == "夜讀")
        #expect(settings.readerAutomaticItems.isEmpty)
        #expect(!settings.isReadingStyleModified)
        // No row is the book's any more: the saved page is the same in every book.
        settings.setReadingBaseline(.chinese)
        settings.synchronizeReadingSettings()
        #expect(settings.lineHeightMultiple == 1.45)

        settings.readerFontSize = 30
        settings.scrollMode = false
        #expect(settings.isReadingStyleModified)

        let stored = try #require(settings.customReadingStyles.first { $0.id == saved.id })
        try settings.applyReadingStyle(stored)
        #expect(settings.readerFontSize == 21)
        #expect(settings.scrollMode)
        #expect(!settings.isReadingStyleModified)

        settings.renameCustomReadingStyle(id: saved.id, to: "睡前")
        #expect(settings.appliedReadingStyleName == "睡前")
        settings.deleteCustomReadingStyle(id: saved.id)
        #expect(settings.appliedReadingStyleName == nil)
        #expect(settings.readerFontSize == 21)
    }

    // MARK: - 只套用到這本書

    @Test func aBooksOwnSetupIsWornOnlyWhileItIsOpen() throws {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        let book = UUID()
        var stored: AppearanceThemeReadingSettings?
        settings.setBookReadingOverride(nil, bookID: book) { stored = $0 }
        #expect(settings.readerFontSize == 18)

        settings.setReadingSetupIsThisBooksOwn(true)
        #expect(stored != nil)
        settings.readerFontSize = 26
        #expect(stored?.fontSize == 26)
        // Neither the theme nor the shared setup heard of it.
        #expect(settings.globalReadingSettings.fontSize == 18)
        #expect(settings.themeReadingSettings(themeID: settings.readingSettingsThemeID)?.fontSize == nil)

        let style = try #require(ReadingStyleLibrary.builtIn(id: "builtin.zhHans.web"))
        try settings.applyReadingStyle(style)
        #expect(stored?.readingStyleID == style.id)
        #expect(settings.readerFontSize == 17)

        // Another reader closing is not this book's.
        settings.clearBookReadingOverride(bookID: UUID())
        #expect(settings.readerFontSize == 17)

        settings.clearBookReadingOverride(bookID: book)
        #expect(settings.readerFontSize == 18)
        #expect(settings.readerReadingStyleID == nil)

        // Opened again, the book wears its own.
        settings.setBookReadingOverride(stored, bookID: book) { stored = $0 }
        #expect(settings.readerFontSize == 17)
        #expect(settings.readerReadingStyleID == style.id)

        // Switched off, its own setup is gone and it reads like the library.
        settings.setReadingSetupIsThisBooksOwn(false)
        #expect(stored == nil)
        #expect(settings.readerFontSize == 18)
        settings.clearBookReadingOverride(bookID: book)
    }

    /// Another device's rows are the library's. They are stored there and never become
    /// part of the open book's own setup.
    @Test func rowsFromAnotherDeviceNeverLandInTheOpenBook() {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        let book = UUID()
        var stored: AppearanceThemeReadingSettings?
        settings.setBookReadingOverride(AppearanceThemeReadingSettings(), bookID: book) { stored = $0 }

        var values = AppearanceThemeReadingSettings()
        values.letterSpacing = 3
        settings.applyReadingSettingsSync([
            ReadingSettingSyncRecord(item: "letterSpacing", values: values, editedAt: Date()),
        ])
        #expect(stored == nil)
        #expect(settings.bookReadingOverride?.letterSpacing == nil)
        #expect(settings.themeReadingSettings(themeID: settings.readingSettingsThemeID)?.letterSpacing == 3)
        settings.clearBookReadingOverride(bookID: book)
    }

    /// A book is the kind its first open worked out, on every open after — and 直排 or
    /// 橫排 Japanese by how it is being read.
    @Test func aBookKeepsTheBaselineItsFirstOpenGaveIt() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = UUID()
        let store = BookReaderSettingsStore(fileURL: url)
        #expect(store.readingBaseline(for: book) == nil)
        store.setReadingBaseline(.japaneseVertical, for: book)

        let reopened = BookReaderSettingsStore(fileURL: url)
        #expect(reopened.readingBaseline(for: book) == .japaneseVertical)
        #expect(reopened.readingBaseline(for: book)?.oriented(vertical: false) == .japaneseHorizontal)
        #expect(ReadingBaseline.english.oriented(vertical: true) == .english)
    }

    @Test func aBooksOwnSetupIsStoredWithTheBook() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = UUID()
        var reading = AppearanceThemeReadingSettings()
        reading.fontSize = 20
        reading.readingStyleID = "builtin.ja.bunko"

        let store = BookReaderSettingsStore(fileURL: url)
        store.setReadingOverride(reading, for: book)
        #expect(BookReaderSettingsStore(fileURL: url).readingOverride(for: book) == reading)

        store.setReadingOverride(nil, for: book)
        #expect(BookReaderSettingsStore(fileURL: url).readingOverride(for: book) == nil)
    }

    // MARK: - Pro

    @Test func readingStylesAreSoldUnderComfortWithTheirOwnHeadline() {
        #expect(PremiumFeature.marketedFeatures().contains(.readingStyles))
        #expect(PremiumPillar.pillar(for: .readingStyles) == .comfort)
        #expect(PremiumPitch.pitch(for: .readingStyles) != PremiumPitch.pitch(for: nil))
    }

    /// Asked where the style is picked: without Pro the paywall opens and nothing is worn.
    @Test func withoutProPickingAStyleOpensThePaywall() throws {
        let fixture = Fixture()
        defer { fixture.restore() }
        fixture.reset()
        let settings = GlobalSettings.shared
        let style = try #require(ReadingStyleLibrary.builtIn(id: "builtin.en.modern"))
        var asked: PremiumFeature?

        ReadingStyleActions.apply(styleID: style.id, isProActive: false) { asked = $0 }
        #expect(asked == .readingStyles)
        #expect(settings.readerReadingStyleID == nil)

        asked = nil
        ReadingStyleActions.apply(styleID: style.id, isProActive: true) { asked = $0 }
        #expect(asked == nil)
        #expect(settings.readerReadingStyleID == style.id)
    }

    // MARK: - Fixture

    /// The live settings, the stores, the saved styles and the open book's setup as they
    /// were, and a known start: 默認, every row with the old defaults and none on 自動.
    @MainActor
    private final class Fixture {
        private let settings = GlobalSettings.shared
        private let lightID: String
        private let darkID: String
        private let themes: [AppearanceCustomTheme]
        private let extrasBaseline: AppearanceThemeExtras?
        private let stores = ReadingSettingsStoresSnapshot()
        private let readerTheme = ReaderTheme.loadPersisted()
        private let reading: AppearanceThemeReadingSettings
        private let styles: [ReadingStyle]
        private let baseline: ReadingBaseline
        var imported: [String] = []

        init() {
            lightID = settings.appearanceThemeID
            darkID = settings.appearanceDarkThemeID
            themes = settings.customAppearanceThemes
            extrasBaseline = settings.appearanceExtrasBaseline
            reading = settings.currentReadingSettingsSnapshot()
            styles = settings.customReadingStyles
            baseline = settings.readingBaseline
        }

        func reset() {
            settings.bookReadingOverride = nil
            settings.bookReadingOverrideBookID = nil
            settings.persistBookReadingOverride = nil
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceExtrasBaseline = nil
            ReadingSettingsStoresSnapshot.clear()
            settings.readingBaseline = .chinese
            settings.selectedReaderFontPostScript = nil
            settings.readerFontSize = 18
            settings.readerFontBold = false
            settings.lineHeightMultiple = 1.65
            settings.letterSpacing = 0
            settings.paragraphSpacingMultiplier = 0.8
            settings.readerFirstLineIndent = 2
            settings.readerTextAlignment = .justified
            settings.pageMarginH = 24
            settings.pageMarginV = 16
            settings.pageMarginTop = 16
            settings.pageMarginBottom = 16
            settings.scrollMode = false
            settings.readerWritingMode = .horizontal
            settings.readerFollowSystemTheme = false
            settings.appearanceBindReaderTheme = false
            ReaderTheme.white.persist()
            ReaderConfig.shared.syncFromGlobalSettings()
            forgetThemeEdits()
        }

        /// The writes above were recorded on 默認 as edits. Empties the stores and captures
        /// 全域 from what is on screen, keeping the rows that are on 自動.
        func forgetThemeEdits() {
            let automatic = settings.readerAutomaticItems
            ReadingSettingsStoresSnapshot.clear()
            settings.readerAutomaticItems = automatic
            _ = settings.globalReadingSettings
        }

        func restore() {
            settings.bookReadingOverride = nil
            settings.bookReadingOverrideBookID = nil
            settings.persistBookReadingOverride = nil
            settings.appearanceThemeID = GlobalSettings.defaultAppearanceThemeID
            settings.appearanceDarkThemeID = GlobalSettings.defaultAppearanceThemeID
            for id in imported { settings.deleteCustomAppearanceTheme(id: id) }
            settings.appearanceExtrasBaseline = nil
            settings.customAppearanceThemes = themes
            settings.customReadingStyles = styles
            settings.readingBaseline = baseline
            readerTheme.persist()
            settings.isApplyingAppearanceExtras = true
            try? settings.writeReadingSettings(reading, origin: .theme)
            settings.isApplyingAppearanceExtras = false
            stores.restore()
            settings.appearanceExtrasBaseline = extrasBaseline
            settings.appearanceThemeID = lightID
            settings.appearanceDarkThemeID = darkID
            ReaderConfig.shared.syncFromGlobalSettings()
        }
    }
}

/// 量測 (design §9.3), the part a test can hold: on every screen width the app runs on,
/// each baseline and built-in style keeps its line inside the measure its language reads
/// comfortably, and a page holds enough lines to be a page.
///
/// Counted from the numbers, not from a rendered page: full-width characters for CJK
/// (one em each), an average Latin letter of 0.5 em for English. Books, Kindle and
/// printed 文庫 were not measured — neither is reachable from a simulator.
@Suite("閱讀樣式量測")
struct ReadingStyleMeasureTests {
    /// iPhone SE, iPhone 17, iPhone 17 Pro Max, and the iPad reader's readable column.
    private static let pages: [(name: String, size: CGSize)] = [
        ("SE", CGSize(width: 320, height: 568)),
        ("iPhone", CGSize(width: 393, height: 852)),
        ("Pro Max", CGSize(width: 440, height: 956)),
        ("iPad column", CGSize(width: 672, height: 1000)),
    ]

    private struct Measure {
        let charactersPerLine: Double
        let linesPerPage: Double
    }

    private static func measure(_ reading: AppearanceThemeReadingSettings, on page: CGSize, latin: Bool) -> Measure {
        let size = reading.fontSize ?? 18
        let vertical = reading.writingMode == "verticalRTL"
        let inline = (vertical ? page.height : page.width)
            - (vertical ? (reading.pageMarginTop ?? 16) + (reading.pageMarginBottom ?? 16) + 120
                        : 2 * (reading.pageMarginH ?? 24))
        let block = (vertical ? page.width : page.height)
            - (vertical ? 2 * (reading.pageMarginH ?? 24)
                        : (reading.pageMarginTop ?? 16) + (reading.pageMarginBottom ?? 16) + 120)
        return Measure(
            charactersPerLine: inline / (size * (latin ? 0.5 : 1)),
            linesPerPage: block / (size * (reading.lineHeightMultiple ?? 1.6))
        )
    }

    @Test func everyBaselineKeepsAReadableMeasure() {
        for baseline in ReadingBaseline.allCases {
            for page in Self.pages {
                let measure = Self.measure(baseline.values, on: page.size, latin: baseline == .english)
                let label = "\(baseline.rawValue) on \(page.name): \(measure.charactersPerLine) × \(measure.linesPerPage)"
                if baseline == .english {
                    // 45–75 characters is the book measure; a phone column runs shorter.
                    #expect((28...80).contains(measure.charactersPerLine), "\(label)")
                } else {
                    // clreq: no fewer than 10, no more than 48 across (55 down).
                    #expect((14...48).contains(measure.charactersPerLine), "\(label)")
                }
                #expect(measure.linesPerPage >= 10, "\(label)")
            }
        }
    }

    @Test func everyBuiltInStyleKeepsAReadableMeasure() {
        for style in ReadingStyleLibrary.builtIns {
            for page in Self.pages {
                let reading = style.values(for: .chinese)
                let vertical = reading.writingMode == "verticalRTL"
                let measure = Self.measure(reading, on: page.size, latin: style.language == .english)
                let label = "\(style.id) on \(page.name): \(measure.charactersPerLine) × \(measure.linesPerPage)"
                if style.language == .english {
                    #expect((28...80).contains(measure.charactersPerLine), "\(label)")
                } else {
                    #expect((14...(vertical ? 55 : 48)).contains(measure.charactersPerLine), "\(label)")
                }
                #expect(measure.linesPerPage >= (vertical ? 6 : 10), "\(label)")
            }
        }
    }
}
