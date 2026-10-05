# Aozora Bunko Support Implementation Plan

> Spec: [青空文庫支援設計](../specs/2026-10-05-aozora-bunko-support-design.md). Evidence: [annotation census](../../aozora/annotation-census-2026-10-05.md). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import official Aozora Bunko downloads, and build the single Aozora parser (document sections, syntax tree, gaiji/accent/kunojiten tables, source map), with unit and corpus tests. Existing TXT books must render exactly as before.

**Scope of this plan:** The spec's decisions are settled:
- route C, converting at import;
- automatic migration of existing Aozora TXT books;
- the bundled CC0 tables;
- gaiji described only by shape shown as `※` followed by the description in smaller type;
- 傍点 in both engines.

Phases 0 and 1a are detailed. Phases 1b, 1c and 2 are outlined and get detailed tasks once Phase 1a lands, because they build on its syntax tree and source map.

**Architecture:** A new `Modules/Core/Aozora/` folder holds the parser:
- a detector;
- a header parser ported from aozora2html `header.rb`;
- a tokenizer;
- a command table;
- a tree builder;
- three lookup tables loaded from bundled JSON;
- a source map between displayed and source UTF-16 offsets.

`AozoraMarkupParser` and the TXT reader are not touched until Phase 1c. The reader does not change in these phases.

**Tech Stack:** Swift 6, Swift Testing, Foundation, `ReadiumZIPFoundation` (already used by `LocalMangaArchive` and `ReaderStylePackage`), Python 3 for the table generator.

---

## Guardrails

- **Toolchain.** Resolve it at call time with `export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"`.
- **Running tests.** Use `bash scripts/xctest.sh -- -only-testing:'yuedu appTests/<Suite>'`.
  - Never hardcode a simulator, OS version or Xcode path.
  - Never pass `-derivedDataPath`.
- **No copyrighted text in the repo.**
  - Unit tests use short self-written snippets.
  - The only real work allowed in fixtures is the public-domain `Fixtures/TXTEncodings/aozora-neko-jijo.txt`.
- **Corpus.** It stays outside the repo. The corpus suite reads `AOZORA_CORPUS`, which reaches the test runner as `TEST_RUNNER_AOZORA_CORPUS=<path>`, and is disabled when the variable is unset.
- **No change to how existing TXT books display.** `AozoraTXTTests`, `TXTReaderIndexMigrationTests` and `TXTLocationMigrationTests` must pass unchanged through Phase 1a.
- **Strings.** Every user-facing string goes through `localized()`, with keys in zh-Hant, zh-Hans and en.
- **Errors.** No `try?` that discards a parse or IO error; log through `AppLogger`, outside `#if DEBUG`.
- **Commits.** Stage exact paths only, one commit per task, English commit messages.

## File map

### Phase 0

- Create `Modules/Core/Aozora/AozoraDocumentDetector.swift`: the detection rule from the spec.
- Create `Modules/Core/Aozora/AozoraHeader.swift`: `AozoraHeader` and `AozoraHeaderParser`, ported from aozora2html `lib/aozora2html/header.rb` (`build_header_info`).
- Modify `Modules/Services/LibraryStore/LocalBookImportService.swift`: the `zip` branch.
- Modify `Modules/Core/TXT/TXTMetadataProbe.swift`: use `AozoraHeaderParser` when the detector matches.
- Tests: create `AozoraDocumentDetectorTests.swift` and `AozoraHeaderTests.swift`; extend `LocalBookImportServiceTests.swift` and `TXTMetadataProbeTests.swift`.

### Phase 1a

- Create `scripts/aozora_tables.py`. It converts aozora2html `yml/jis2ucs.yml` and `yml/accent_table.yml` from pinned commit `9ca5395` into:
  - `Resources/Assets/aozora-jis2ucs.json`
  - `Resources/Assets/aozora-accent.json`
  - `Resources/Assets/aozora-tables.manifest.json` (upstream commit and SHA-256 of inputs and outputs)
- `Resources/` is a file-system-synchronized group, so no `.pbxproj` edit is needed.
- Modify `NOTICE`: credit aozora2html (CC0) for the tables and the ported rules.
- Create in `Modules/Core/Aozora/`:
  - `AozoraTables.swift`
  - `AozoraSyntax.swift`
  - `AozoraTokenizer.swift`
  - `AozoraCommandTable.swift`
  - `AozoraDocumentParser.swift`
  - `AozoraSourceMap.swift`
  - `AozoraDiagnostics.swift`
- Tests: `AozoraTablesTests`, `AozoraTokenizerTests`, `AozoraDocumentStructureTests`, `AozoraInlineRulesTests`, `AozoraAnnotationTests`, `AozoraSourceMapTests`, `AozoraCorpusTests`.

---

## Task 1: Detect Aozora documents

**Files:**
- Create: `Modules/Core/Aozora/AozoraDocumentDetector.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraDocumentDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Cases:
- the PD fixture is detected;
- a self-written file with only a `底本：` colophon and one `［＃３字下げ］` is detected;
- a Chinese TXT with `《書名》` and no colophon is not detected;
- a `readme.txt` sample is not detected;
- every existing non-Aozora TXT fixture under `Fixtures/TXTEncodings/` is not detected.

- [ ] **Step 2: Implement**

```swift
enum AozoraDocumentDetector {
    /// A titled notation block (【テキスト中に現れる記号について】 between two
    /// hyphen lines), or a 底本： colophon plus ［＃ or ｜…《…》 in the text.
    /// Measured on the 2023-03 corpus: 93.4% of works; the misses carry no markup.
    static func isAozoraDocument(_ text: String) -> Bool
}
```

Read only a bounded prefix and suffix, so a large non-Aozora TXT is not scanned whole.

- [ ] **Step 3: Run and commit**

```bash
export DEVELOPER_DIR="$(bash scripts/sim.sh xcode)"
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraDocumentDetectorTests'
git add Modules/Core/Aozora/AozoraDocumentDetector.swift "Tests/iOS/yuedu appTests/AozoraDocumentDetectorTests.swift"
git commit -m "feat(aozora): detect Aozora Bunko documents"
```

## Task 2: Import official Aozora zips

**Files:**
- Modify: `Modules/Services/LibraryStore/LocalBookImportService.swift`
- Modify: `Tests/iOS/yuedu appTests/LocalBookImportServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Build the zips inside the test with `Archive(url:accessMode: .create)`:
- the PD fixture zipped → imported as a TXT book whose text equals the fixture;
- images only → manga, as today;
- images plus a non-Aozora `readme.txt` → manga;
- audio → audiobook, as today.

- [ ] **Step 2: Implement**

- In the `zip` branch, after the audio check, look for a `.txt` entry that `AozoraDocumentDetector` accepts.
- If one exists, extract it to a temporary file and call `store.importTxt(url:title:)`. Images in the zip are ignored until Phase 1b.
- Otherwise keep the manga import.
- Remove the temporary file whether or not the import succeeds, and log failures with `AppLogger`.

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/LocalBookImportServiceTests'
git commit -m "fix(import): open official Aozora Bunko zips as books instead of manga"
```

## Task 3: Read the title and author from the Aozora header

**Files:**
- Create: `Modules/Core/Aozora/AozoraHeader.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraHeaderTests.swift`
- Modify: `Modules/Core/TXT/TXTMetadataProbe.swift`
- Modify: `Tests/iOS/yuedu appTests/TXTMetadataProbeTests.swift`

- [ ] **Step 1: Port `build_header_info`**

The header is the lines before the first blank line. Port the assignment of title, original title, subtitle, author, translator, editor and 編訳 for header lengths 2–6, including the "original" test (a line made only of ASCII and the listed JIS rows) and the 編／訳／編訳 patterns.

```swift
struct AozoraHeader: Equatable, Sendable {
    var title: String
    var originalTitle: String?
    var subtitle: String?
    var originalSubtitle: String?
    var author: String?
    var translator: String?
    var editor: String?
    var henyaku: String?
}

enum AozoraHeaderParser {
    static func parse(headerLines: [String]) -> AozoraHeader?
}
```

- [ ] **Step 2: Tests**

Write one self-written header for each length from 2 to 6. Include a translated work, so the author and the translator are kept apart.

- [ ] **Step 3: Use it in the probe**

In `TXTMetadataProbe.infer`, when `AozoraDocumentDetector` accepts the sample, take the title and author from `AozoraHeaderParser`. Otherwise keep the current patterns. The PD fixture must yield the title 『吾輩は猫である』中篇自序 and the author 夏目漱石, not the filename.

- [ ] **Step 4: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraHeaderTests' -only-testing:'yuedu appTests/TXTMetadataProbeTests'
git commit -m "fix(import): read the title and author of Aozora Bunko files from their header"
```

## Task 4: Bundle the gaiji and accent tables

**Files:**
- Create: `scripts/aozora_tables.py`
- Create: `Resources/Assets/aozora-jis2ucs.json`
- Create: `Resources/Assets/aozora-accent.json`
- Create: `Resources/Assets/aozora-tables.manifest.json`
- Create: `Modules/Core/Aozora/AozoraTables.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraTablesTests.swift`
- Modify: `NOTICE`

- [ ] **Step 1: Generate the tables**

```bash
git clone --depth 1 https://github.com/aozorahack/aozora2html /tmp/aozora2html
git -C /tmp/aozora2html checkout 9ca5395
python3 scripts/aozora_tables.py /tmp/aozora2html Resources/Assets
```

Expected: 11,233 JIS entries.
- `jis2ucs.yml` values are numeric character references; decode them, including multi-scalar sequences such as か゚.
- `accent_table.yml` maps a base character plus a mark to a JIS code. Store it as `base + mark → JIS code`, resolved through the JIS table at load time.
- Running the script twice must produce identical bytes.

- [ ] **Step 2: Loader and tests**

`AozoraTables` loads both files once with `Bundle.main.url(forResource:withExtension:)` and logs a missing or corrupt resource through `AppLogger`.

Test these mappings:

| JIS code | Expected |
|---|---|
| 1-84-77 | 挘 |
| 1-2-24 | ヿ |
| 2-1-1 | U+20089 (outside the BMP) |
| 1-4-87 | U+304B U+309A |
| 1-2-54 | U+FF5F |
| 1-2-55 | U+FF60 |

Also test one accent mapping per mark type that `accent_table.yml` defines.

- [ ] **Step 3: NOTICE and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraTablesTests'
git commit -m "feat(aozora): bundle the JIS X 0213 and accent tables from aozora2html (CC0)"
```

## Task 5: Syntax tree and tokenizer

**Files:**
- Create: `Modules/Core/Aozora/AozoraSyntax.swift`
- Create: `Modules/Core/Aozora/AozoraTokenizer.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraTokenizerTests.swift`

- [ ] **Step 1: Types**

```swift
indirect enum AozoraInline: Equatable, Sendable {
    case text(String)
    case ruby(base: [AozoraInline], reading: String, side: AozoraSide)
    case emphasis(AozoraEmphasisStyle, side: AozoraSide, [AozoraInline])   // 9 styles from command_table.yml
    case sideline(AozoraSidelineStyle, side: AozoraSide, [AozoraInline])   // solid, double, chain, dashed, wave
    case bold([AozoraInline]), italic([AozoraInline])
    case size(steps: Int, [AozoraInline])
    case tateChuYoko([AozoraInline])
    case gaiji(AozoraGaiji)
    case script(AozoraScriptKind, [AozoraInline])                          // superscript, subscript, line-right, line-left
    case kaeriten(String), kuntenOkurigana(String)
    case warichu([AozoraInline])
    case editorialNote(String)                                             // never displayed
    case unknownAnnotation(String)                                         // never displayed; counted in diagnostics
}

enum AozoraBlock: Equatable, Sendable {
    case paragraph([AozoraInline], AozoraParagraphStyle)                   // indent, hanging indent, end alignment + offset, size
    case heading(AozoraHeadingLevel, AozoraHeadingKind, [AozoraInline])    // 大/中/小 × normal/同行/窓
    case pageBreak(AozoraPageBreakKind)                                    // 改ページ/改丁/改段/改見開き
    case image(source: String, width: Int?, height: Int?, caption: [AozoraInline])
}

struct AozoraGaiji: Equatable, Sendable {
    var resolved: String?                                                  // nil for description-only
    var description: String
    var code: AozoraGaijiCode?                                             // .jis(plane:row:cell) or .unicode(UInt32)
}
```

- [ ] **Step 2: Tokenizer**

Tokens:
- text runs;
- `｜`;
- `《…》`;
- `［＃…］`, including notes that span lines, as the current `stripNotes` allows;
- `※［＃…］`;
- `〔…〕`;
- `／＼` and `／″＼`;
- newline.

Every token carries its source UTF-16 range.

- [ ] **Step 3: Tests and commit**

Cover:
- each token kind;
- unterminated `［＃` and `《`, which stay text;
- a note spanning lines;
- that the token ranges cover the source exactly once.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraTokenizerTests'
git commit -m "feat(aozora): add the syntax tree and tokenizer"
```

## Task 6: Document sections

**Files:**
- Create: `Modules/Core/Aozora/AozoraDocumentParser.swift` (sections only in this task)
- Create: `Tests/iOS/yuedu appTests/AozoraDocumentStructureTests.swift`

- [ ] **Step 1: Implement the aozora2html states**

- Header: until the first blank line; parsed by `AozoraHeaderParser`.
- Notation block: a hyphen line within the next five non-blank lines opens it, and the next hyphen line closes it. Drop the content.
- Body.
- Colophon: from the first line starting with `底本：` after the body starts. Keep its lines, and extract 底本, 初出, 入力 and 校正.

- [ ] **Step 2: Tests and commit**

Cover:
- with and without a notation block;
- an unclosed notation block (the rest is body, plus a diagnostic);
- no colophon;
- the PD fixture: the header has two lines, the body starts after the second hyphen line (line 16), and the colophon starts at `底本：` (line 43).

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraDocumentStructureTests'
git commit -m "feat(aozora): split documents into header, notation block, body and colophon"
```

## Task 7: Inline rules — ruby, gaiji, accent, kunojiten

**Files:**
- Modify: `Modules/Core/Aozora/AozoraDocumentParser.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraInlineRulesTests.swift`

- [ ] **Step 1: Ruby**

- `｜` fixes the base start.
- Without `｜`, the base is the preceding run of one character class: kanji (including 々〆ヶ and gaiji), hiragana, katakana, full-width alphanumerics or half-width alphanumerics. Port the classes from aozora2html `ruby_buffer.rb`.
- In Aozora documents every `《…》` is ruby. The current kana-reading guard belongs to the TXT path only.

- [ ] **Step 2: Gaiji**

- A JIS code (`[12]-row-cell`, with or without 第3／第4水準) resolves through `AozoraTables`.
- `U+XXXX` resolves directly.
- Anything else stays `resolved == nil`, with the description kept.
  - It displays as `※` followed by the description in full-width parentheses, with the page-line reference dropped: `※［＃「口＋世」、ページ数-行数］` → `※（口＋世）` (spec decision 4).
  - Phase 1b renders the parenthesised part in smaller type.
- A gaiji counts as kanji for ruby, so `※［＃コト、1-2-24］《こと》` becomes ruby over ヿ.

- [ ] **Step 3: Accent decomposition and kunojiten**

- `〔…〕` containing a letter followed by a mark converts through the accent table and loses the brackets. Otherwise the brackets stay.
- `／＼` → U+3033 U+3035, and `／″＼` → U+3034 U+3035.

- [ ] **Step 4: Tests and commit**

Cover each rule, plus:
- the PD fixture's two gaiji followed by ruby, which become ruby;
- a gaiji outside the BMP;
- a combining sequence;
- a description-only gaiji, displayed as `※（口＋世）` with the page-line reference dropped;
- `〔注〕`, which stays as written.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraInlineRulesTests'
git commit -m "feat(aozora): resolve ruby, gaiji, accents and kunojiten"
```

## Task 8: Annotations — command table, forward references, ranges, blocks

**Files:**
- Create: `Modules/Core/Aozora/AozoraCommandTable.swift`
- Modify: `Modules/Core/Aozora/AozoraDocumentParser.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraAnnotationTests.swift`

- [ ] **Step 1: Command table**

Start from aozora2html `yml/command_table.yml`. Add the categories the census counts:
- 字下げ, 地付き／字上げ／寄せ, 見出し, 改ページ類, 字級, 太字, 斜体;
- 傍点 (9 styles), 傍線 (5 styles);
- 縦中横, 割り注, 上下標／小書き, 返り点, 訓点送り仮名, 罫囲み;
- images and captions;
- editorial notes (`底本では`, `ママ`, …).

The census script's `CATEGORIES` list is the cross-check.

- [ ] **Step 2: Forward references**

`［＃「X」に傍点］`, `［＃「X」は太字］`, `［＃「X」は中見出し］`: find the nearest preceding X in the same paragraph, matching base text without ruby readings, and wrap it. If X is not found, record a diagnostic and drop the annotation.

- [ ] **Step 3: Ranges and blocks**

- Handle `［＃傍点］…［＃傍点終わり］` and `［＃ここから…］…［＃ここで…終わり］` with a style stack (see `style_stack.rb`).
- Close an unclosed range at block end, with a diagnostic.
- Line-start `［＃N字下げ］`, `［＃地付き］` and `［＃地からN字上げ］` set the paragraph style.
- A standalone `［＃改ページ］` becomes a page break.

- [ ] **Step 4: Tests and commit**

Cover:
- each category;
- nesting (傍点 inside 太字 inside a heading);
- a forward reference whose target has ruby;
- a missing target;
- an unclosed range.

Unknown annotations become `.unknownAnnotation` and never reach the displayed text.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraAnnotationTests'
git commit -m "feat(aozora): parse annotations into the syntax tree"
```

## Task 9: Source map

**Files:**
- Create: `Modules/Core/Aozora/AozoraSourceMap.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraSourceMapTests.swift`

- [ ] **Step 1: Implement**

- The displayed text is the document's visible text: blocks joined by `"\n"`. Ruby readings, notes and unknown annotations are excluded, and a description-only gaiji contributes `※（description）`.
- The map is a sorted list of runs (displayed start, source start, displayed length, source length). It supports deletions (markup), replacements (gaiji, accents, kunojiten) and growth (gaiji outside the BMP).
- API: `displayedOffset(forSource:)` and `sourceOffset(forDisplayed:)`. Both are monotonic. Inside a replaced run, an offset maps to the run's start.

- [ ] **Step 2: Tests and commit**

Round-trip every token boundary of the PD fixture. Also cover a non-BMP gaiji and a run that grows.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraSourceMapTests'
git commit -m "feat(aozora): map displayed offsets to source offsets"
```

## Task 10: Diagnostics and timing

**Files:**
- Create: `Modules/Core/Aozora/AozoraDiagnostics.swift`
- Modify: `Modules/Core/Aozora/AozoraDocumentParser.swift`

- [ ] **Step 1: Implement**

Each document gets one `AppLogger` summary line with counts per diagnostic kind: unknown annotations by shape, missing forward references, unclosed ranges and unresolved gaiji. Do not log each occurrence. Wrap `parse` in a `SourcePerfTrace` span named `aozora.parse`.

- [ ] **Step 2: Commit**

```bash
git commit -m "feat(aozora): summarise parse diagnostics and time the parser"
```

## Task 11: Corpus suite

**Files:**
- Create: `Tests/iOS/yuedu appTests/AozoraCorpusTests.swift`

- [ ] **Step 1: Implement**

Enable the suite only when `AOZORA_CORPUS` is set. Pick one file per work the same way `scripts/aozora_annotation_census.py` does. Assert:
- no parse throws;
- no displayed text contains `［＃`, an unmatched `《`/`》`, `／＼`, or a `〔…〕` with an accent mark;
- the only unresolved gaiji are description-only;
- totals match the census JSON within 1% (gaiji types, heading count).

- [ ] **Step 2: Run on the Mac**

```bash
git clone --depth 1 https://github.com/aozorahack/aozorabunko_text ~/aozorabunko_text
TEST_RUNNER_AOZORA_CORPUS=~/aozorabunko_text bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraCorpusTests'
```

Record the parse time of the largest file (2.07 MB) from the `aozora.parse` span on a device.

- [ ] **Step 3: Commit**

```bash
git commit -m "test(aozora): check the parser against the full Aozora corpus"
```

---

## Phase 1b (outline — route C, convert at import)

- **Writer.** `AozoraEPUBWriter` turns the syntax tree into EPUB 3 with `Archive(url:accessMode: .create)`.
  - The `mimetype` entry comes first and is stored uncompressed.
  - It writes `package.opf` (title, author, translator, `ja`), `nav.xhtml` from heading levels, one XHTML file per section, one app-owned stylesheet, and the images the document references.
  - It does not set `writing-mode`.
  - A description-only gaiji is written as `※` plus a smaller `（…）` span. Size only, no colour, so reader themes still apply.
- **Sections.** Split at 大／中見出し. Text before the first heading forms its own section, and the colophon is the last section. When there are no headings and the body exceeds 100 KB, split at paragraph boundaries.
- **Engine text parity test (Mac).** For each converted chapter, the text that `BrowserChapterLayout.sourceText` and the legacy builder produce equals the writer's displayed text. Positions depend on it.
- **Import.**
  - Aozora `.txt` and `.zip` go through the writer.
  - The book is stored as `source = "local_epub"`, and the original bytes are kept next to it.
  - The converter version and the source encoding are recorded on the book.
- **Regeneration.** When the converter version changes, the EPUB is regenerated on open. A corpus test proves that style-only changes keep every chapter's text.

## Phase 1c (outline — automatic migration on first open)

1. **Coordinate-space tag, one release first.** Add a coordinate-space id to synced reading positions. New clients ignore remote positions from another space. Confirm that the decoding of `SyncEnvelope<CoreTextReadingPosition>` tolerates the unknown field on old clients.
2. **Inverse projection.** Add the inverse of `displayedOffset(forSourceOffset:)` for the TXT path.
3. **Migration service.** Use the journal order of `TXTReaderIndexMigrationService`: write the journal, then commit bookmarks, then positions, then switch the book record, then delete the journal.
   - Bookmarks map their start and end separately.
   - If any mapping cannot be proven, the book stays on the TXT path and remains readable, with a diagnostic.
4. **One parser.** `AozoraMarkupParser` delegates to the new module in a TXT-compatible mode: it strips notes, keeps the kana-reading guard, and does no gaiji, accent or kunojiten conversion. `AozoraTXTTests` pass unchanged.

## Phase 2 (outline)

- **CSS group.** Map 字下げ, 地付き／字上げ, headings, page breaks, 字級, 太字 and 斜体 in the app stylesheet. Check each mapping in horizontal and vertical writing in both engines.
- **傍点／傍線.** Show them in both engines (spec decision 5), so a chapter that falls back to the legacy engine keeps them: `text-emphasis` in YueduCoreText, plus an equivalent in the legacy engine.
