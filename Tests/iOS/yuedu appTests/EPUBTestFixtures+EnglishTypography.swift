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

    static func englishTypography() -> Sample {
        let filler = (0..<8).map { index in
            """
            <p style="hyphens:auto; text-align:justify">
              Synthetic paragraph \(index) uses ordinary English words to exercise native line wrapping.
            </p>
            """
        }.joined(separator: "\n")
        return Sample(entries: makeBaseEntries(
            title: "English Typography",
            language: "en-US",
            body: """
            <h1 id="start">English Typography Probe</h1>
            <p id="offset-probe" style="hyphens:none; text-align:justify">
              <a href="#target">linked words</a> extra­ordinary marker after
            </p>
            \(filler)
            <p id="target" style="hyphens:auto; text-align:justify">
              Anchor target closes the synthetic typography fixture.
            </p>
            """,
            extraManifest: "",
            extraEntries: [:]
        ))
    }

    static func englishTypographyChapters() -> Sample {
        var entries = makeBaseEntries(
            title: "English Typography Chapters",
            language: "en-US",
            body: """
            <h1>Chapter One</h1>
            <p style="hyphens:auto; text-align:justify">
              A synthetic opening chapter carries enough ordinary words to form several lines.
            </p>
            """,
            extraManifest: "",
            extraEntries: [:]
        )
        guard var package = entries["OPS/package.opf"].flatMap({ String(data: $0, encoding: .utf8) })
        else { return Sample(entries: entries) }
        package = package.replacingOccurrences(
            of: "</manifest>",
            with: """
                <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
            """
        )
        package = package.replacingOccurrences(
            of: "</spine>",
            with: """
                <itemref idref="ch2"/>
              </spine>
            """
        )
        entries["OPS/package.opf"] = Data(package.utf8)
        entries["OPS/chapter2.xhtml"] = Data(xhtml(
            title: "Chapter Two",
            body: """
            <h1>Chapter Two</h1>
            <p style="hyphens:auto; text-align:justify">
              A separate synthetic chapter restarts its own independent text and layout ranges.
            </p>
            """
        ).utf8)
        return Sample(entries: entries)
    }
}
