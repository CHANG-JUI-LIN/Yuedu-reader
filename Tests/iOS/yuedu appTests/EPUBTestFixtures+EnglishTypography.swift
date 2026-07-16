import Foundation

extension EPUBTestFixtures {
    static func englishLanguagePrecedence() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "English Language Precedence",
            language: "en-US",
            bodyAttributes: #"lang="en-GB""#,
            body: """
            <p id="language-ranges">
              British colour;
              <span xml:lang="fr">français courant</span>;
              <span lang="!!!">fallback language</span>;
              <code>sample code text</code>.
            </p>
            """,
            extraManifest: "",
            extraEntries: [:]
        ))
    }

    static func englishPackageLanguageOnly() -> Sample {
        Sample(entries: makeBaseEntries(
            title: "English Package Language",
            language: "en-US",
            body: "<p>package language fallback</p>",
            extraManifest: "",
            extraEntries: [:]
        ))
    }
}
