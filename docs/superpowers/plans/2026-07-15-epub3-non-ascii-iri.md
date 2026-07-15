# EPUB 3 Non-ASCII Resource IRI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open EPUB spine resources when Readium exposes a percent-encoded IRI but the package/archive uses the equivalent Unicode path.

**Architecture:** Keep normalization at `PublicationSession`'s single Readium resource lookup boundary. Generate raw, slash-normalized, percent-decoded, and canonically encoded candidates, deduplicate them as normalized `AnyURL` values, and let existing `resource(for:)` and `link(for:)` consumers share the fix.

**Tech Stack:** Swift 6, Readium Shared, Foundation URL/IRI handling, Swift Testing, `EPUBTestFixtures`

---

### Task 1: Reproduce the encoded/decoded mismatch with a minimal EPUB

**Files:**
- Create: `Tests/iOS/yuedu appTests/EPUBTestFixtures+NonASCIIIRI.swift`
- Create: `Tests/iOS/yuedu appTests/EPUBResourceIRITests.swift`

- [ ] **Step 1: Add a Unicode-filename fixture**

```swift
import Foundation

extension EPUBTestFixtures {
    static func nonASCIIResourceIRI() -> Sample {
        Sample(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">urn:yuedu:non-ascii-iri</dc:identifier>
                <dc:title>草枕 fixture</dc:title><dc:language>ja</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="one" href="xhtml/一.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="one"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(xhtml(
                title: "目次",
                body: #"<nav epub:type="toc"><ol><li><a href="xhtml/一.xhtml">一</a></li></ol></nav>"#
            ).utf8),
            "OPS/xhtml/一.xhtml": Data(xhtml(
                title: "一",
                body: "<h1>一</h1><p>山路を登りながら、こう考えた。</p>"
            ).utf8),
        ])
    }
}
```

- [ ] **Step 2: Write the failing chapter and custom-scheme assertions**

```swift
import Foundation
import Testing
@testable import yuedu_app

struct EPUBResourceIRITests {
    @Test
    func encodedSpineHrefReadsUnicodeArchiveEntry() async throws {
        let sample = EPUBTestFixtures.nonASCIIResourceIRI()
        let url = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: url)
        let chapter = try #require(session.chapters.first)

        #expect(chapter.href.contains("%E4%B8%80.xhtml"))
        let html = try await session.chapterHTML(at: chapter.index)
        #expect(html.contains("山路を登りながら"))

        let request = session.resourceURL(for: "OPS/xhtml/一.xhtml")
        let response = try await session.response(for: request)
        #expect(String(data: response.data, encoding: .utf8)?.contains("山路を登りながら") == true)
    }
}
```

- [ ] **Step 3: Run the focused test and verify RED**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/EPUBResourceIRITests' \
  -parallel-testing-enabled NO
```

Expected: FAIL at `chapterHTML(at:)` with
`resourceReadFailed("OPS/xhtml/%E4%B8%80.xhtml")`. If the fixture does not
produce an encoded descriptor, inspect Readium's returned href and adjust only
the fixture packaging—not the assertion that both representations resolve.

### Task 2: Normalize both IRI representations at the resource boundary

**Files:**
- Modify: `Modules/Core/EPUB/PublicationSession.swift`
- Test: `Tests/iOS/yuedu appTests/EPUBResourceIRITests.swift`

- [ ] **Step 1: Replace `readiumURLs(for:)` candidate construction**

Keep the existing `AnyURL.normalized` deduplication and replace only the raw
three-element candidate list with this representation expansion:

```swift
private func readiumURLs(for href: String) -> [AnyURL] {
    let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
    let basePath = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    let decodedPath = basePath.removingPercentEncoding ?? basePath
    let encodedPath = decodedPath.addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed
    ) ?? decodedPath
    let candidates = [
        trimmed,
        basePath,
        "/\(basePath)",
        decodedPath,
        "/\(decodedPath)",
        encodedPath,
        "/\(encodedPath)",
    ]

    var seen = Set<String>()
    return candidates.compactMap { candidate in
        guard let url = AnyURL(legacyHREF: candidate) else { return nil }
        let normalized = url.normalized
        guard seen.insert(normalized.string).inserted else { return nil }
        return normalized
    }
}
```

Do not decode bytes after `Resource.read()`, alter `chapterIndex(for:)`, extract
the ZIP, or special-case Japanese filenames. The same candidate function must
continue to serve `resource(for:)` and `link(for:)`.

- [ ] **Step 2: Run the focused test and verify GREEN**

Run the Task 1 command again.

Expected: both the spine read and the custom-scheme response contain the
Japanese probe. The original descriptor remains percent-encoded; lookup, not
publication metadata, is normalized.

- [ ] **Step 3: Run nearby EPUB regressions**

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/EPUBResourceIRITests' \
  -only-testing:'yuedu appTests/EPUBRenderingTests' \
  -only-testing:'yuedu appTests/EPUBCFIResolverTests' \
  -parallel-testing-enabled NO
```

Expected: PASS. In particular, existing percent-encoded obfuscated-filename
links and CFI/fragment resolution must not regress.

- [ ] **Step 4: Commit the regression and fix**

```bash
git add Modules/Core/EPUB/PublicationSession.swift \
  'Tests/iOS/yuedu appTests/EPUBTestFixtures+NonASCIIIRI.swift' \
  'Tests/iOS/yuedu appTests/EPUBResourceIRITests.swift'
git commit -m "fix: resolve non-ASCII EPUB resource IRIs"
```

### Task 3: Prove the official failure family and record evidence

**Files:**
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-002/README.md`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-002/before.png`
- Create: `docs/build-week/epub3/evidence/BW-EPUB3-002/after.png`
- Modify: `docs/build-week/epub3/compatibility-matrix.md`

- [ ] **Step 1: Run the official corpus and inspect all three variants**

```bash
ROOT=$(git rev-parse --show-toplevel)
TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1 \
TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR="$ROOT/.build-week/epub3-samples/books" \
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -parallel-testing-enabled NO
```

Expected: all 42 sample cases run with zero skips, and `kusamakura`,
`kusamakura-preview`, and `kusamakura-preview-embedded` pass the open/render
checkpoint. Do not alter expected probes to produce a pass.

- [ ] **Step 2: Capture chapter 一 before and after**

Use `kusamakura` on iPhone 17 Pro Max / iOS 27.0 / vertical writing / paged
mode. Baseline must show the safe load failure state without a crash; after must
show chapter 一 body content. Keep identical orientation, page, and crop.

- [ ] **Step 3: Write the evidence README**

```markdown
# BW-EPUB3-002 — Non-ASCII EPUB resource IRI

- Sample/checkpoint: kusamakura / open the non-ASCII chapter 一 spine resource
- Sample checksum: 6d4d4ed5eda3f612e3263c54fa0f74ccfa87260f43e81bb58ea658636e52eeb7
- Baseline commit: dd62d8047aaef47bd93dee4c6c4af277ac628f26
- After commit: paste the 40-character output of `git rev-parse HEAD` for the Task 2 fix commit
- Fixture: `EPUBTestFixtures+NonASCIIIRI.swift` / `nonASCIIResourceIRI()`
- Test command: `xcodebuild test -project Yuedu-Reader.xcodeproj -scheme 'Yuedu-Reader' -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:'yuedu appTests/EPUBResourceIRITests' -parallel-testing-enabled NO`
- Device/iOS/settings: iPhone 17 Pro Max / iOS 27.0 / vertical writing, paged, defaults
- Expected behavior: chapter 一 resolves and its Japanese body remains readable
- Observed behavior: baseline resource lookup failed on the encoded href; the fixed build reads the equivalent Unicode archive path
- Official content visible: yes
- License attribution: CC BY-SA 3.0 (official catalog default; no sample-specific exception listed); source: https://idpf.github.io/epub3-samples/30/samples.html#kusamakura
```

Replace the After commit instruction with the command's exact SHA before
running `matrix-check`.

- [ ] **Step 4: Update matrix rows and validate**

Update `kusamakura`, `kusamakura-preview`, and
`kusamakura-preview-embedded` only after each has been rerun. Link
`BW-EPUB3-002`, the focused test, evidence directory, and fix SHA. A sample with
an unverified manual checkpoint must not be promoted beyond its evidence.

```bash
python3 scripts/epub3_samples.py matrix-check
python3 -m unittest discover -s Tests/Tools -p 'test_epub3_samples.py' -v
git diff --check
git add docs/build-week/epub3/compatibility-matrix.md \
  docs/build-week/epub3/evidence/BW-EPUB3-002
git commit -m "docs: record non-ASCII EPUB IRI evidence"
```
