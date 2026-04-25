import Foundation
import Testing
@testable import yuedu_app

@Suite("GlobalSettings Localization")
struct GlobalSettingsLocalizationTests {
    @Test("traditional chinese returns source string")
    func traditionalChineseReturnsSourceString() {
        let translated = localized("書架", bundle: testBundle(localizations: ["zh-Hant"]))

        #expect(translated == "書架")
    }

    @Test("english localized string comes from bundle")
    func englishLocalizedStringComesFromBundle() {
        let translated = localized(
            "系統語言提示",
            bundle: testBundle()
        )

        #expect(translated == "System language hint")
    }

    @Test("missing localized string falls back to source key")
    func missingLocalizedStringFallsBackToSourceKey() {
        let translated = localized(
            "不存在的字串",
            bundle: testBundle(localizations: ["en"])
        )

        #expect(translated == "不存在的字串")
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
            "書架" = "Library";
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
