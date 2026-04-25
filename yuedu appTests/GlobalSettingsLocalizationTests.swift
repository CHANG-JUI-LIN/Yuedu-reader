import Foundation
import Testing
@testable import yuedu_app

@Suite("GlobalSettings Localization")
struct GlobalSettingsLocalizationTests {
    @Test("traditional chinese returns source string")
    func traditionalChineseReturnsSourceString() {
        let translated = GlobalSettings.translatedString(
            "書架",
            language: .traditionalChinese,
            bundle: testBundle()
        )

        #expect(translated == "書架")
    }

    @Test("simplified chinese converts source string")
    func simplifiedChineseConvertsSourceString() {
        let translated = GlobalSettings.translatedString(
            "書架",
            language: .simplifiedChinese,
            bundle: testBundle()
        )

        #expect(translated == "书架")
    }

    @Test("english prefers dictionary values")
    func englishPrefersDictionaryValues() {
        let translated = GlobalSettings.translatedString(
            "書架",
            language: .english,
            bundle: testBundle()
        )

        #expect(translated == "Library")
    }

    @Test("english falls back to localized string when key is missing from dictionary")
    func englishFallsBackToLocalizedString() {
        let translated = GlobalSettings.translatedString(
            "系統語言提示",
            language: .english,
            bundle: testBundle()
        )

        #expect(translated == "System language hint")
    }

    @Test("system language uses bundle localization instead of effective app language")
    func systemLanguageUsesBundleLocalization() {
        let translated = GlobalSettings.translatedString(
            "系統語言提示",
            language: .systemLanguage,
            bundle: testBundle(localizations: ["en"])
        )

        #expect(translated == "System language hint")
    }

    private func testBundle(localizations: [String] = ["en", "zh-Hant"]) -> Bundle {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let infoPlistURL = rootURL.appendingPathComponent("Info.plist")

        try! FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>test.localization.bundle</string>
            <key>CFBundleName</key>
            <string>TestLocalization</string>
            <key>CFBundlePackageType</key>
            <string>BNDL</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleDevelopmentRegion</key>
            <string>zh-Hant</string>
            <key>CFBundleLocalizations</key>
            <array>
                \(localizations.map { "<string>\($0)</string>" }.joined(separator: "\n        "))
            </array>
        </dict>
        </plist>
        """
        try! infoPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        let stringsByLocalization = [
            "en": """
            "系統語言提示" = "System language hint";
            """,
            "zh-Hant": """
            "系統語言提示" = "系統語言提示";
            """
        ]

        for (localization, contents) in stringsByLocalization where localizations.contains(localization) {
            let localizationURL = rootURL.appendingPathComponent("\(localization).lproj", isDirectory: true)
            try! FileManager.default.createDirectory(
                at: localizationURL,
                withIntermediateDirectories: true
            )
            try! contents.write(
                to: localizationURL.appendingPathComponent("Localizable.strings"),
                atomically: true,
                encoding: .utf8
            )
        }

        return Bundle(url: rootURL)!
    }
}
