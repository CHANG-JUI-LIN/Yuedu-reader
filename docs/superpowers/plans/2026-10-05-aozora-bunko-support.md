# Aozora Bunko Support Implementation Plan

> Spec: [青空文庫支援設計](../specs/2026-10-05-aozora-bunko-support-design.md). Evidence: [annotation census](../../aozora/annotation-census-2026-10-05.md). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import official Aozora Bunko downloads, build the single Aozora parser (document sections, syntax tree, gaiji/accent/kunojiten tables, source map), and convert Aozora documents to EPUB 3 at import (Phase 1b), with unit and corpus tests. Existing TXT books must render exactly as before.

**Scope of this plan:** The spec's decisions are settled:
- route C, converting at import;
- automatic migration of existing Aozora TXT books;
- the bundled CC0 tables;
- gaiji described only by shape shown as `※` followed by the description in smaller type;
- 傍点 in both engines.

Phases 0, 1a and 1b are detailed. Phases 1c, 1d and 2 are outlined and get detailed tasks when the phase before them lands.

Vertical writing for Aozora books (Phase 1d) waits for the [vertical typography plan](2026-10-06-vertical-typography.md) (maintainer decision, 2026-10-06): both engines must first set punctuation, Latin, digits and kana as W3C requires. Phase 1b ships Aozora books horizontal only.

**Architecture:** A new `Modules/Core/Aozora/` folder holds the parser:
- a detector;
- a header parser ported from aozora2html `header.rb`;
- a tokenizer;
- a command table;
- a tree builder;
- three lookup tables loaded from bundled JSON;
- a source map between displayed and source UTF-16 offsets.

`AozoraMarkupParser` and the TXT reader are not touched until Phase 1c. The reader does not change in Phases 0 to 1b, except for the gate that regenerates a converted book (Task 20). Phase 1d changes three reader gates so a converted book follows the 排版方向 setting.

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
- **Strings.** Every user-facing string goes through `localized()`, with keys in every `Resources/*.lproj`: zh-Hant, zh-Hans, en, ja and ko. `ruby scripts/check_localizations.rb` (macOS) checks them.
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

### Phase 1b

- Modify `Modules/Core/Aozora/AozoraDocumentParser.swift`: ASCII whitespace in the displayed text (Task 12) and block spans (Task 13).
- Create in `Modules/Core/Aozora/`:
  - `AozoraChapterPlanner.swift`: chapters, navigation entries, per-chapter text and source map;
  - `AozoraXHTMLWriter.swift`: chapter XHTML and the app's stylesheet;
  - `AozoraEPUBWriter.swift`: the OCF package and its `yuedu-aozora.json` manifest.
- Create in `Modules/Services/LibraryStore/`: `AozoraBookImporter.swift` and `AozoraBookRegenerator.swift`.
- Modify:
  - `Modules/Services/LibraryStore/Models.swift` (`ReadingBook.aozora`);
  - `LocalBookImportService.swift`, `BookStore.swift` (`delete`);
  - `Modules/Services/iCloud/ICloudSyncManager.swift` (`bookFilePayloads`);
  - `Modules/Services/Calibre/CalibreWirelessService.swift` (`returnBookFile`);
  - `Modules/Features/Reader/BookReaderView.swift` (the regeneration gate).
- Create `docs/aozora/epub-text-contract.md`: what each engine makes of the XHTML the writer emits.
- Tests: `AozoraChapterPlannerTests`, `AozoraXHTMLWriterTests`, `AozoraEPUBWriterTests`, `AozoraEngineParityTests`, `AozoraBookImportTests`, `AozoraBookRegeneratorTests`; extend `AozoraInlineRulesTests`, `AozoraSourceMapTests`, `LocalBookImportServiceTests` and `AozoraCorpusTests`.

---

## Task 1: Detect Aozora documents

**Files:**
- Create: `Modules/Core/Aozora/AozoraDocumentDetector.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraDocumentDetectorTests.swift`

- [x] **Step 1: Write the failing tests**

Cases:
- the PD fixture is detected;
- a self-written file with only a `底本：` colophon and one `［＃３字下げ］` is detected;
- a Chinese TXT with `《書名》` and no colophon is not detected;
- a `readme.txt` sample is not detected;
- every existing non-Aozora TXT fixture under `Fixtures/TXTEncodings/` is not detected.

- [x] **Step 2: Implement**

```swift
enum AozoraDocumentDetector {
    /// A titled notation block (【テキスト中に現れる記号について】 between two
    /// hyphen lines), or a 底本： colophon plus ［＃ or ｜…《…》 in the text.
    /// Measured on the 2023-03 corpus: 93.4% of works; the misses carry no markup.
    static func isAozoraDocument(_ text: String) -> Bool
}
```

Read only a bounded prefix and suffix, so a large non-Aozora TXT is not scanned whole.

- [x] **Step 3: Run and commit**

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

- [x] **Step 1: Write the failing tests**

Build the zips inside the test with `Archive(url:accessMode: .create)`:
- the PD fixture zipped → imported as a TXT book whose text equals the fixture;
- images only → manga, as today;
- images plus a non-Aozora `readme.txt` → manga;
- audio → audiobook, as today.

- [x] **Step 2: Implement**

- In the `zip` branch, after the audio check, look for a `.txt` entry that `AozoraDocumentDetector` accepts.
- If one exists, extract it to a temporary file and call `store.importTxt(url:title:)`. Images in the zip are ignored until Phase 1b.
- Otherwise keep the manga import.
- Remove the temporary file whether or not the import succeeds, and log failures with `AppLogger`.

- [x] **Step 3: Run and commit**

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

- [x] **Step 1: Port `build_header_info`**

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

- [x] **Step 2: Tests**

Write one self-written header for each length from 2 to 6. Include a translated work, so the author and the translator are kept apart.

- [x] **Step 3: Use it in the probe**

In `TXTMetadataProbe.infer`, when `AozoraDocumentDetector` accepts the sample, take the title and author from `AozoraHeaderParser`. Otherwise keep the current patterns. The PD fixture must yield the title 『吾輩は猫である』中篇自序 and the author 夏目漱石, not the filename.

- [x] **Step 4: Run and commit**

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

- [x] **Step 1: Generate the tables**

```bash
git clone --depth 1 https://github.com/aozorahack/aozora2html /tmp/aozora2html
git -C /tmp/aozora2html checkout 9ca5395
python3 scripts/aozora_tables.py /tmp/aozora2html Resources/Assets
```

Expected: 11,233 JIS entries.
- `jis2ucs.yml` values are numeric character references; decode them, including multi-scalar sequences such as か゚.
- `accent_table.yml` maps a base character plus a mark to a JIS code. Store it as `base + mark → JIS code`, resolved through the JIS table at load time.
- Running the script twice must produce identical bytes.

- [x] **Step 2: Loader and tests**

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

- [x] **Step 3: NOTICE and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraTablesTests'
git commit -m "feat(aozora): bundle the JIS X 0213 and accent tables from aozora2html (CC0)"
```

## Task 5: Syntax tree and tokenizer

**Files:**
- Create: `Modules/Core/Aozora/AozoraSyntax.swift`
- Create: `Modules/Core/Aozora/AozoraTokenizer.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraTokenizerTests.swift`

- [x] **Step 1: Types**

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

- [x] **Step 2: Tokenizer**

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

- [x] **Step 3: Tests and commit**

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

- [x] **Step 1: Implement the aozora2html states**

- Header: until the first blank line; parsed by `AozoraHeaderParser`.
- Notation block: a hyphen line within the next five non-blank lines opens it, and the next hyphen line closes it. Drop the content.
- Body.
- Colophon: from the first line starting with `底本：` after the body starts. Keep its lines, and extract 底本, 初出, 入力 and 校正.

- [x] **Step 2: Tests and commit**

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

- [x] **Step 1: Ruby**

- `｜` fixes the base start.
- Without `｜`, the base is the preceding run of one character class: kanji (including 々〆ヶ and gaiji), hiragana, katakana, full-width alphanumerics or half-width alphanumerics. Port the classes from aozora2html `ruby_buffer.rb`.
- In Aozora documents every `《…》` is ruby. The current kana-reading guard belongs to the TXT path only.

- [x] **Step 2: Gaiji**

- A JIS code (`[12]-row-cell`, with or without 第3／第4水準) resolves through `AozoraTables`.
- `U+XXXX` resolves directly.
- Anything else stays `resolved == nil`, with the description kept.
  - It displays as `※` followed by the description in full-width parentheses, with the page-line reference dropped: `※［＃「口＋世」、ページ数-行数］` → `※（口＋世）` (spec decision 4).
  - Phase 1b renders the parenthesised part in smaller type.
- A gaiji counts as kanji for ruby, so `※［＃コト、1-2-24］《こと》` becomes ruby over ヿ.

- [x] **Step 3: Accent decomposition and kunojiten**

- `〔…〕` containing a letter followed by a mark converts through the accent table and loses the brackets. Otherwise the brackets stay.
- `／＼` → U+3033 U+3035, and `／″＼` → U+3034 U+3035.

- [x] **Step 4: Tests and commit**

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

- [x] **Step 1: Command table**

Start from aozora2html `yml/command_table.yml`. Add the categories the census counts:
- 字下げ, 地付き／字上げ／寄せ, 見出し, 改ページ類, 字級, 太字, 斜体;
- 傍点 (9 styles), 傍線 (5 styles);
- 縦中横, 割り注, 上下標／小書き, 返り点, 訓点送り仮名, 罫囲み;
- images and captions;
- editorial notes (`底本では`, `ママ`, …).

The census script's `CATEGORIES` list is the cross-check.

- [x] **Step 2: Forward references**

`［＃「X」に傍点］`, `［＃「X」は太字］`, `［＃「X」は中見出し］`: find the nearest preceding X in the same paragraph, matching base text without ruby readings, and wrap it. If X is not found, record a diagnostic and drop the annotation.

- [x] **Step 3: Ranges and blocks**

- Handle `［＃傍点］…［＃傍点終わり］` and `［＃ここから…］…［＃ここで…終わり］` with a style stack (see `style_stack.rb`).
- Close an unclosed range at block end, with a diagnostic.
- Line-start `［＃N字下げ］`, `［＃地付き］` and `［＃地からN字上げ］` set the paragraph style.
- A standalone `［＃改ページ］` becomes a page break.

- [x] **Step 4: Tests and commit**

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

- [x] **Step 1: Implement**

- The displayed text is the document's visible text: blocks joined by `"\n"`. Ruby readings, notes and unknown annotations are excluded, and a description-only gaiji contributes `※（description）`.
- The map is a sorted list of runs (displayed start, source start, displayed length, source length). It supports deletions (markup), replacements (gaiji, accents, kunojiten) and growth (gaiji outside the BMP).
- API: `displayedOffset(forSource:)` and `sourceOffset(forDisplayed:)`. Both are monotonic. Inside a replaced run, an offset maps to the run's start.

- [x] **Step 2: Tests and commit**

Round-trip every token boundary of the PD fixture. Also cover a non-BMP gaiji and a run that grows.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraSourceMapTests'
git commit -m "feat(aozora): map displayed offsets to source offsets"
```

## Task 10: Diagnostics and timing

**Files:**
- Create: `Modules/Core/Aozora/AozoraDiagnostics.swift`
- Modify: `Modules/Core/Aozora/AozoraDocumentParser.swift`

- [x] **Step 1: Implement**

Each document gets one `AppLogger` summary line with counts per diagnostic kind: unknown annotations by shape, missing forward references, unclosed ranges and unresolved gaiji. Do not log each occurrence. Wrap `parse` in a `SourcePerfTrace` span named `aozora.parse`.

- [x] **Step 2: Commit**

```bash
git commit -m "feat(aozora): summarise parse diagnostics and time the parser"
```

## Task 11: Corpus suite

**Files:**
- Create: `Tests/iOS/yuedu appTests/AozoraCorpusTests.swift`

- [x] **Step 1: Implement**

Enable the suite only when `AOZORA_CORPUS` is set. Pick one file per work the same way `scripts/aozora_annotation_census.py` does. Assert:
- no parse throws;
- no displayed text contains `［＃`, an unmatched `《`/`》`, `／＼`, or a `〔…〕` with an accent mark;
- the only unresolved gaiji are description-only;
- totals match the census JSON within 1% (gaiji types, heading count).

- [x] **Step 2: Run on the Mac**

```bash
git clone --depth 1 https://github.com/aozorahack/aozorabunko_text ~/aozorabunko_text
TEST_RUNNER_AOZORA_CORPUS=~/aozorabunko_text bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraCorpusTests'
```

Record the parse time of the largest file (2.07 MB) from the `aozora.parse` span on a device.

- [x] **Step 3: Commit**

```bash
git commit -m "test(aozora): check the parser against the full Aozora corpus"
```

## Phase 0 and 1a: what landed

2026-10-06. Phase 0: 155f7cfd, 164a49ae, 70d8b2b6. Phase 1a: bd7e992c, ca09ace3, aed5871b, 7b515265, 7cd0c5f4, d6a393fb, 46646885, 61d37b88, f5223b37.

Phase 1b builds on these decisions, made while implementing:

- **Notation block.** A hyphen-fenced block after the header is dropped only when it explains notation: a `《》：`-style definition, or 記号／表記について in its title. The corpus has 16,007 such blocks and 3 hyphen-fenced blocks of body text; one of them holds 1,125 lines of poems.
- **Displayed text.**
  - A line holding only annotations is no block, and its line break goes with it.
  - A mid-line 地付き／字上げ followed by text splits the line, the tail end-aligned (1,705 works); the "\n" between the two blocks stands for the annotation. Written after the text, it aligns the whole line.
  - 割り注 gets （） unless the text already has them, as in aozora2html.
  - 返り点, 訓点送り仮名 and the caption of a 「…」のキャプション付きの図 are displayed text.
  - A figure contributes only its caption. Before any position migration, Phase 1b must reconcile this with what each engine emits for an image.
- **Headings.** A line holding one heading (any kind) is a heading block. A heading sharing its line with other text stays inline (`AozoraInline.heading`): nearly every 同行 and 窓 heading. The lines of ［＃ここから…見出し］ make one heading, with `.lineBreak` between them.
- **Figures.** `AozoraBlock.image` for a figure alone on its line; `AozoraInline.image` for one set into text (840 in the corpus).
- **Corpus check.** Leaks are judged by provenance: no displayed unit is a verbatim copy of a ruby, annotation, gaiji or くの字点 token. The corpus quotes the notation itself with gaiji (［］ are 1-1-46/47, 《》 1-1-52/53) and carries a few stray brackets as typos, so a plain search for ［＃ or 《 finds text, not markup.

Corpus run, 17,158 works:

| Check | Result | Census |
|---|---:|---:|
| Decode failures | 0 | |
| Markup units copied into the text | 0 | |
| 〔…〕 left with a known decomposition | 0 | |
| Gaiji: JIS / U+ / description only | 46,692 / 3,313 / 3,138 | 46,666 / 3,313 / 3,138 |
| Works with a heading / two or more | 3,572 / 3,511 | 3,577 / 3,513 |
| Unknown annotations | 2,556 in 524 works | |

The unknown annotations are long-tail layout notes, led by ページの左右中央 (712 in 214 works), 「…」～「…」に傍点 (200 in 2 works) and typefaces (ゴシック体).

Parse time of the largest file (2.07 MB): 593 ms on the iOS 27 simulator by its `aozora.parse` span (1,040 ms while the corpus suite parses other works concurrently), 316 ms in a macOS build of the same sources. A device measurement is still to be recorded.

---

## Phase 1b: EPUB writer and import

Route C: an Aozora document becomes an EPUB 3 file at import, and from then on is stored and opened as an ordinary local EPUB. Phase 1b ships these books horizontal only; vertical writing is Phase 1d.

### The text contract

A reading position is `(spineIndex, charOffset)`. `charOffset` indexes the text of whichever engine lays the chapter out: `BrowserChapterLayout.sourceText` under BrowserAuto, or the legacy builder's attributed string after a fallback.

The spec assumed that clean XHTML makes the two texts equal. It does not. On 2026-10-06 a temporary probe gave both engines the same chapters, horizontal and vertical, paged and scroll, on the iOS 27 simulator:

| XHTML | BrowserAuto | Legacy |
|---|---|---|
| `<p>A</p><p>B</p>` | `AB`: blocks get no separator | `A\nB\n` |
| `<p>A<br class="eol"/></p>`, with `br.eol { display: block }` | `A\n` | `A\n` |
| `<p>A<br/></p>` | `A\n` | `A`, U+2028, `\n` |
| `<br/>` inside a block | `\n` | U+2028 (same length) |
| `<h1>` | like `<h2>` | adds a leading `\n` |
| `<img>`, inline or alone in a block | nothing: `BoxTreeBuilder.appendImageRun` gives it no source text, by design | U+FFFC |
| ASCII space at a block's edge or next to `<br/>` | kept | dropped |
| two ASCII spaces, or a tab | one space | one space |
| `white-space: pre-wrap` | honoured | ignored |
| `"q"`, `'r'` | unchanged | curled (same length) |
| `page-break-before` | ignored | adds U+200B |
| U+3000, also at edges and alone in a block | kept | kept |
| ruby, `<span>`, `<sub>`, `<sup>`, `<em>`, nested `<div>` blocks | identical | identical |

BrowserAuto's paged and scroll texts were identical. It fell back to legacy for a non-default `ruby-position`, and, in vertical writing, for any chapter holding an `<img>` (`VerticalTextSupport.accepts`, `LogicalFlow.swift:89`).

The legacy builder's cleanup of spaces between Han characters (`HTMLAttributedStringBuilder.swift:517`) never runs: ICU rejects the `\u{00A0}` in its pattern, and the `try?` leaves the regex nil. U+3000 survives in legacy only because of that. (55711b23 deleted the cleanup on 2026-10-06.)

So the writer follows these rules, and Task 17 pins them:
- **End of block.** Every block ends with `<br class="eol"/>`, and the stylesheet sets `br.eol { display: block }`. A blank line is `<p><br class="eol"/></p>`. A chapter's text is each block's displayed text followed by `"\n"`.
- **Line break inside a block.** `<br/>`.
- **Headings.** `<h3>`, `<h4>`, `<h5>` as aozora2html writes them; never `<h1>`. The probe checked `<h2>` to `<h4>`; Task 17 covers `<h5>`.
- **Page breaks.** They end the chapter (Task 14); the stylesheet has no page-break property.
- **Stylesheet limits.** No `writing-mode`, `ruby-position`, `@media`, `calc()`, tables, floats or positioning.
- **U+3000.** Written as `&#12288;`, so the text does not depend on that cleanup staying broken; it was later deleted (55711b23).
- **ASCII whitespace.** Collapsed in the displayed text itself (Task 12).
- **Figures.** A figure costs legacy one U+FFFC that BrowserAuto does not have, and no markup removes that difference.
  - The chapter text keeps BrowserAuto's form: a figure contributes only its caption, as Phase 1a defined.
  - In a chapter that legacy lays out, an offset after a figure is one unit later for each figure before it.
  - Works with figures are 2.8% of the corpus, and every EPUB with images already behaves this way.

### Versions

- `AozoraEPUBWriter.converterVersion` changes with any change to the files the writer produces.
- `AozoraEPUBWriter.textVersion` changes only when some chapter's text changes. A text change ships with a position migration (Phase 1c's tools), never alone.
- Both start at 1.

## Task 12: ASCII whitespace in the displayed text

**Files:**
- Modify: `Modules/Core/Aozora/AozoraDocumentParser.swift`
- Modify: `Tests/iOS/yuedu appTests/AozoraInlineRulesTests.swift`
- Modify: `Tests/iOS/yuedu appTests/AozoraSourceMapTests.swift`

The engines disagree about ASCII whitespace at a block's edge, and both collapse runs, so the displayed text must already be collapsed. This revises Phase 1a, before any position is stored against it.

- [ ] **Step 1: Write the failing tests**

| Source line | Displayed text | Source map |
|---|---|---|
| `A  B` | `A B` | second space deleted |
| `A`, tab, `B` | `A B` | tab replaced by a space |
| ` lead` and `trail ` | `lead` and `trail` | edge spaces deleted |
| `A ［＃「A」に傍点］ B` | `A B` | the run across the annotation collapses |
| heading lines `上 ` and ` 下` in ［＃ここから見出し］ | `上`, `\n`, `下` | spaces next to the line break deleted |
| `　本文　` | unchanged | U+3000 is not ASCII whitespace |
| spaces only | an empty block | |

- [ ] **Step 2: Implement**

Apply CSS `white-space: normal` to U+0020 and U+0009 over a block's leaves in order, across inline boundaries:
- a run collapses to one space, and a surviving tab becomes a space;
- a run at the start or end of a block, or next to a `.lineBreak`, is deleted.

Do it where the parser freezes a block. Split text nodes so the kept units stay identity runs. Leave U+3000, U+00A0 and other spaces alone.

- [ ] **Step 3: Corpus and commit**

Rerun `AozoraCorpusTests`; every Phase 1a check still passes. Record:
- how many works' displayed text changed;
- how many hold U+00A0 in the displayed text. The legacy builder drops a block holding only U+00A0, so if the corpus has such blocks, Task 17 gets a case for them.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraInlineRulesTests' -only-testing:'yuedu appTests/AozoraSourceMapTests'
git commit -m "feat(aozora): collapse ASCII whitespace in the displayed text as HTML does"
```

## Task 13: Block spans

**Files:**
- Modify: `Modules/Core/Aozora/AozoraDocumentParser.swift`
- Modify: `Tests/iOS/yuedu appTests/AozoraSourceMapTests.swift`

The writer cuts chapters between blocks, so it needs each block's place in the displayed text and in the source.

- [ ] **Step 1: Implement**

`AozoraDocument` keeps its segments and gains one span per block, in document order. `AozoraBlockParser.emit` records each span as it appends the block's segments.

```swift
struct AozoraBlockSpan: Equatable, Sendable {
    enum Section: Equatable, Sendable { case header, body, colophon }
    var section: Section
    /// Index into `headerBlocks`, `body` or `colophon`.
    var index: Int
    /// The "\n" segment before this block; nil for the document's first block.
    var separator: Int?
    /// The block's own segments.
    var leaves: Range<Int>
}
```

- [ ] **Step 2: Tests and commit**

Use the PD fixture, plus a fixture with a page break and a line split by 地付き. Assert:
- each span's leaves spell its block's `displayedText`;
- the separators and leaves, in order, rebuild `displayedText`;
- a page-break block has no leaves.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraSourceMapTests'
git commit -m "feat(aozora): record where each block sits in the displayed text"
```

## Task 14: Chapters and navigation

**Files:**
- Create: `Modules/Core/Aozora/AozoraChapterPlanner.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraChapterPlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

Use short self-written documents. Chapters:
- the header is the title page, and the colophon is the last chapter;
- a 大見出し or 中見出し block starts a chapter; a 小見出し or an inline heading does not;
- every page break (改ページ, 改丁, 改段, 改見開き) ends a chapter;
- body text before the first heading is a chapter of its own;
- blank blocks at the start and end of a chapter are dropped, and a chapter left empty disappears;
- a chapter over the limit splits before the block that would cross it; a single block longer than the limit stays whole;
- a chapter's text is each block's text plus `"\n"`; page breaks contribute nothing;
- the chapter's source map sends every offset inside a block to the same source offset as the document's map, and the `"\n"` after a block to the line break that followed it.

Navigation:
- the title page is listed under the work's title;
- each heading block and inline heading is listed at its level, pointing at its anchor;
- parts of a split chapter are listed as `題(1)`, `題(2)`, … as `TXTChapterParser.swift:216` titles them;
- the colophon is listed as `底本`;
- text before the first heading has no entry of its own, unless it is split into parts.

- [ ] **Step 2: Implement**

```swift
struct AozoraChapter: Equatable, Sendable {
    enum Role: Equatable, Sendable { case titlePage, body, colophon }
    var role: Role
    var spans: [AozoraBlockSpan]
    var navigation: [AozoraNavigationEntry]
    var text: String
    var sourceMap: AozoraSourceMap
}

struct AozoraNavigationEntry: Equatable, Sendable {
    var title: String
    /// 1 大, 2 中, 3 小. The title page, parts and the colophon are 1.
    var level: Int
    /// The element id, or nil for the chapter's start.
    var anchor: String?
}
```

- **Limit.** 51,200 UTF-16 units. The TXT path splits at 100 KB of source bytes (`TXTChapterParser.swift:173`), which is 51,200 characters of Shift_JIS text.
- **Chapter map.** Build it with `AozoraSourceMap(segments:source:)` from the chapter's spans: each span's leaves, then a `"\n"` segment.
  - That segment's source is the separator of the block that follows in the document.
  - After the document's last block, it is empty, at the end of the source.
- **Anchors.** `h` plus the block's index among all spans (`h12`), so regeneration keeps them stable. A heading that starts its chapter points at the chapter itself, with no fragment.
- **Heading titles.** A multi-line heading's title joins its lines with a space.

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraChapterPlannerTests'
git commit -m "feat(aozora): plan chapters and navigation from the syntax tree"
```

## Task 15: Chapter XHTML

**Files:**
- Create: `Modules/Core/Aozora/AozoraXHTMLWriter.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraXHTMLWriterTests.swift`

Class names follow aozora2html (`lib/aozora2html.rb` and `yml/command_table.yml` at the pinned `9ca5395`), so the app's stylesheet reads like 青空文庫's own. Phase 1b's stylesheet gives most of them no rule yet; Phase 2 does.

- [ ] **Step 1: Write the failing tests**

One test per row, comparing the written `<body>` content with the expected string.

| Syntax tree | XHTML |
|---|---|
| paragraph | `<p>…<br class="eol"/></p>` |
| empty paragraph | `<p><br class="eol"/></p>` |
| 字下げ, 地付き, 字詰め, 字の大きさ | classes on the `<p>`: `jisage_2`, plus `first_1` when the first line differs (折り返して); `chitsuki_1`; `jizume_20`; `dai1`, `sho2` |
| heading block 大, 中, 小 | `<h3 class="o-midashi" id="h3">…<br class="eol"/></h3>`, `h4.naka-midashi`, `h5.ko-midashi` |
| 同行, 窓 heading | class `dogyo-o-midashi`, `mado-o-midashi`, …; inline: `<span>` with that class and an id |
| `.lineBreak` | `<br/>` |
| ruby | `<ruby>漢字<rt>かんじ</rt></ruby>`; left side adds `class="left"` |
| 傍点, 左に傍点 | `<em class="sesame_dot">`, `<em class="sesame_dot_after">` |
| 傍線, 左に傍線 | `<em class="underline_solid">`, `<em class="overline_solid">` |
| 太字, 斜体 | `<span class="futoji">`, `<span class="shatai">` |
| inline 字の大きさ | `<span class="dai1">`, `<span class="sho1">` |
| 縦中横 | `<span class="tcy">` |
| 上付き and 行右小書き; 下付き and 行左小書き | `<sup class="superscript">`; `<sub class="subscript">` |
| 返り点, 訓点送り仮名 | `<sub class="kaeriten">`, `<sup class="okurigana">` |
| 割り注 | `<span class="warichu">（…）</span>` |
| 罫囲み, 横組み, キャプション | `<span class="keigakomi">`, `yokogumi`, `caption` |
| description-only gaiji | `※<span class="notes">（口＋世）</span>` |
| figure in a line | `<img class="illustration" src="../images/…" alt="…" width="…" height="…"/>` (`photo` for 写真), `alt` holding the caption, which also follows it in `<span class="caption">` |
| figure alone on its line | the same inside `<p class="figure">…<br class="eol"/></p>` |
| figure whose file is missing | its caption only |
| editorial note, unknown annotation, page break | nothing |
| `&`, `<`, `>` | escaped |
| U+3000 | `&#12288;` |

Also test the whole document: XML declaration, `<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">`, a `<title>`, the stylesheet link, and no whitespace between blocks.

- [ ] **Step 2: Implement**

`AozoraXHTMLWriter.document(for chapter: AozoraChapter, in document: AozoraDocument, images: [String: String]) -> String`. `images` maps a figure's source name to its path in the package.

`AozoraXHTMLWriter.stylesheet` for Phase 1b:

```css
br.eol { display: block; }
p { margin: 0; }
.notes { font-size: 0.8em; }
```

Size only, no colour, so reader themes still apply.

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraXHTMLWriterTests'
git commit -m "feat(aozora): write chapter XHTML that both engines read as the same text"
```

## Task 16: EPUB package

**Files:**
- Create: `Modules/Core/Aozora/AozoraEPUBWriter.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraEPUBWriterTests.swift`

- [ ] **Step 1: Write the failing tests**

Write the PD fixture plus a document with a figure (a PNG made in the test). Assert:
- the first entry is `mimetype`, stored uncompressed, holding `application/epub+zip`;
- `PublicationSession.open` reads the title, author and language `ja`, and finds one chapter per planned chapter;
- `session.tocEntries` match the planned navigation, titles, levels and fragments;
- the figure is in the package and its `src` resolves;
- `yuedu-aozora.json` decodes, and each chapter's recorded length and SHA-256 match the planned text.

- [ ] **Step 2: Implement**

`AozoraEPUBWriter.write(_ document: AozoraDocument, chapters: [AozoraChapter], images: [String: URL], source: AozoraEPUBManifest.Source, identifier: String, to url: URL) async throws -> AozoraEPUBManifest`.

Write the archive with `Archive(url:accessMode: .create)`, as `ReaderStylePackage.swift:123` does:
- `mimetype` first, `compressionMethod: .none`;
- `META-INF/container.xml`;
- `OPS/package.opf`: EPUB 3; `dc:identifier`, `dc:title`, `dc:creator` (role `aut`), `dc:contributor` for the translator (`trl`) and the editor (`edt`), `dc:language` `ja`, `dcterms:modified`. No `primary-writing-mode` and no `page-progression-direction`: Phase 1b is horizontal.
- `OPS/nav.xhtml`: nested `<ol>` by level;
- `OPS/text/c0001.xhtml`, …;
- `OPS/style/aozora.css`;
- `OPS/images/…`: only the figures the document names;
- `OPS/yuedu-aozora.json`, in the manifest as `application/json` and not in the spine.

The manifest file holds:
- `converterVersion`, `textVersion` and `identifier`;
- the source's SHA-256, encoding and UTF-16 length;
- per chapter: href, UTF-16 length, SHA-256 of the UTF-8 text, and its source map runs as flat integer arrays.

The maps are what a later text-changing upgrade migrates positions with; a newer parser cannot rebuild an older version's text.

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraEPUBWriterTests'
git commit -m "feat(aozora): package converted chapters as an EPUB 3 file"
```

## Task 17: Engine parity

**Files:**
- Create: `Tests/iOS/yuedu appTests/AozoraEngineParityTests.swift`
- Create: `docs/aozora/epub-text-contract.md`

- [ ] **Step 1: Write the test**

Convert one self-written document that uses every construct in Task 15's table, plus collapsed ASCII spaces, U+3000 at block edges, blank lines, a split 地付き line and a multi-line heading. For every chapter, in `.horizontal` and `.verticalRTL`, compare with the planned chapter text:
- BrowserAuto's paged text (`BrowserLayoutPageEngine.testLayout(for:)`) and its scroll text (`BrowserScrollTile.chapter.document.sourceText`): equal;
- the legacy builder's text (`EPUBAttributedStringBuilder.buildChapter`) with U+2028 read as `"\n"`, curled quotes read as straight, and U+FFFC removed: equal;
- legacy's U+FFFC count equals the chapter's figures.

`EPUBAuthoredFontCascadeTests` shows how to drive both engines.

Also pin the engine choice. `choice(for:)` is `.browser` for every chapter in horizontal writing, and for every chapter without a figure in vertical writing. A future CSS rule that silently sends chapters to legacy fails here.

- [ ] **Step 2: Document the contract**

`docs/aozora/epub-text-contract.md` holds the probe table above, the rules, and the figure exception. Anyone changing the writer's markup or the stylesheet must keep this test green.

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraEngineParityTests'
git commit -m "test(aozora): pin the text both engines read from a converted chapter"
```

## Task 18: Import

**Files:**
- Create: `Modules/Services/LibraryStore/AozoraBookImporter.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraBookImportTests.swift`
- Modify: `Modules/Services/LibraryStore/Models.swift`
- Modify: `Modules/Services/LibraryStore/LocalBookImportService.swift`
- Modify: `Modules/Services/Calibre/CalibreWirelessService.swift`
- Modify: `Tests/iOS/yuedu appTests/LocalBookImportServiceTests.swift`

Every way a file arrives already goes through `LocalBookImportService.importBook`: Files (`AddBookView`), the share extension (`SharedImportQueueDrainer`), Calibre wireless and the UI-test hook. That one switch is the only place to change.

- [ ] **Step 1: Write the failing tests**

- **Aozora `.txt`** (the PD fixture):
  - becomes a book with `source == "local_epub"` and pipeline `.epub`, titled and credited from the header;
  - its original bytes are kept unchanged as `<epub stem>.aozora.txt`;
  - `book.aozora` records that file and the encoding;
  - the EPUB opens.
- **Official `.zip` with a figure**: the same, with the figure in the EPUB and the original kept as `.aozora.zip`.
- **Plain `.txt`, comic `.zip`, audio `.zip`**: unchanged.
- **Encoding**: a book without `aozora` encodes with no `aozora` key, so its iCloud hash does not change. An Aozora book round-trips.
- **Calibre**: `returnBookFile` sends an Aozora book's original. Calibre's `lpath` names the `.txt` or `.zip` it sent, and its registry holds that file's SHA-256.

The Phase 0 tests that expect a zip to open as TXT change to expect the EPUB.

- [ ] **Step 2: Implement**

`ReadingBook` gains an optional field, encoded only when present (see `audioPlayMode` on why):

```swift
/// Set on a book converted from an Aozora Bunko text: the original file, kept
/// next to the EPUB, and the encoding it was read with.
var aozora: AozoraBookSource?

struct AozoraBookSource: Codable, Equatable, Sendable {
    var originalFilename: String
    var sourceEncoding: UInt   // String.Encoding.rawValue
}
```

The converter version is not stored on the book. A synced field would tell device B that its copy was regenerated when only device A's was. The version lives in the EPUB's own `yuedu-aozora.json` (Task 16).

`AozoraBookImporter.importBook(at:title:store:)`:
1. **Off the main actor:**
   - For a zip, list its entries, take the first visible `.txt` that `AozoraDocumentDetector` accepts, and extract the figures it names.
   - Detect the encoding with `TXTFileReader.detectEncodingBySampling` and decode.
   - Parse, plan, and write the EPUB to a temporary file.
   - Time it as `aozora.import.convert`.
2. **On the main actor:**
   - `store.importEpub(url:title:author:requireValidPublication: true)`, so a package Readium rejects never reaches the shelf.
   - Copy the original into Documents, set `book.aozora`, then `store.saveReadingBook(book)`.
3. **Failure or cancellation:** remove the EPUB, the original copy and the temporary files.

The zip probe moves from `LocalBookImportService` into the importer, so one type reads Aozora zips.

`LocalBookImportService.importBook`:
- **`txt`:** decode, and send the file to the importer when the detector accepts it.
- **`zip`:** audio first, as now; then Aozora; otherwise manga.
- The comment saying figures are not imported yet goes.

A conversion failure surfaces as an import error; there is no TXT fallback. The corpus suite (Task 21) shows every work converts.

`TXTMetadataProbe`'s Aozora branch (Phase 0) is no longer reached from import. It stays until Phase 1c settles how existing TXT Aozora books are read.

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraBookImportTests' -only-testing:'yuedu appTests/LocalBookImportServiceTests'
git commit -m "feat(aozora): import Aozora texts and zips as converted EPUB books"
```

## Task 19: Sync and delete

**Files:**
- Modify: `Modules/Services/iCloud/ICloudSyncManager.swift`
- Modify: `Modules/Services/LibraryStore/BookStore.swift`
- Modify: `Tests/iOS/yuedu appTests/AozoraBookImportTests.swift`

- [ ] **Step 1: Write the failing tests**

- The files iCloud syncs for an Aozora book are the EPUB, the original and the cover.
- `BookStore.delete(bookId:)` removes the original as well as the EPUB.

- [ ] **Step 2: Implement**

- **Sync.** `bookFilePayloads` (`ICloudSyncManager.swift:1227`) also appends `book.aozora?.originalFilename`, under the same condition as the content file (`syncableContentFilename`, `:1253`). Expose the per-book list as a static function, so the test reads it the way existing tests read `syncableContentFilename`.
- **Delete.** In `BookStore.delete(bookId:)` (`BookStore.swift:1276`), remove the original next to the content file.

Upload markers are `recordName:size` (`:1280`), and restore only fetches missing files. So a regenerated EPUB re-uploads when its size changes, and another device keeps its own copy and regenerates it from the synced original (Task 20).

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraBookImportTests'
git commit -m "feat(aozora): sync and delete the original next to the converted book"
```

## Task 20: Regenerate when the converter changes

**Files:**
- Create: `Modules/Services/LibraryStore/AozoraBookRegenerator.swift`
- Create: `Tests/iOS/yuedu appTests/AozoraBookRegeneratorTests.swift`
- Modify: `Modules/Features/Reader/BookReaderView.swift`

- [ ] **Step 1: Write the failing tests**

| EPUB's manifest | Result |
|---|---|
| current `converterVersion` | untouched |
| older `converterVersion`, same `textVersion`, every chapter's text unchanged | replaced; `Caches/spine_cache_<stem>.json` deleted |
| older `converterVersion`, but a chapter's text changed | untouched, logged: a text change needs a migration |
| older `textVersion` | untouched, logged, for the same reason |
| missing or undecodable | regenerated, like version 0, and the failure logged |
| newer than this build | untouched: never downgrade |
| original not on this device yet | untouched, logged; regenerates on a later open |
| book open in another reader (`ReadingResourceUsage.isInUse`) | untouched until it closes |

- [ ] **Step 2: Implement**

`AozoraBookRegenerator.prepare(book:store:) async throws`:
1. Read `OPS/yuedu-aozora.json` from the EPUB with `Archive`.
2. If it needs regenerating, convert the original into a staging file.
3. Check the staging file with `PublicationSession.open`.
4. Compare every chapter's length and SHA-256 with the old manifest.
5. Replace the EPUB with `FileManager.replaceItemAt`, and delete its spine cache. The cache is keyed by file name (`PublicationSession.swift:424`), which regeneration keeps.

Time it as `aozora.regenerate`.

In `BookReaderView`, gate `ReaderView` on `prepare` for a book with `aozora`, the same way the remote gate at `BookReaderView.swift:27` waits for `remoteLibrary.prepare`. Opening never waits on a failure: a failed regeneration logs and opens the existing EPUB.

The CloudKit book-file sync treats content files as immutable (`ICloudSyncManager.swift:1277`). With the behaviour Task 19 describes, each device regenerates its own copy, and a copy from a newer converter is left alone.

- [ ] **Step 3: Run and commit**

Record the `aozora.regenerate` time for the largest work on the simulator.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/AozoraBookRegeneratorTests'
git commit -m "feat(aozora): regenerate a converted book when only its styling changed"
```

## Task 21: Corpus conversion

**Files:**
- Modify: `Tests/iOS/yuedu appTests/AozoraCorpusTests.swift`
- Create: `Tests/iOS/yuedu appTests/Fixtures/aozora-chapter-text-baseline.tsv`

- [ ] **Step 1: Implement**

For every work, still opt-in through `AOZORA_CORPUS`:
- convert it and open it with `PublicationSession.open`;
- check that the session's chapter count and table of contents match the plan;
- check that the chapter texts, joined, equal the displayed text minus what Task 14 drops: page breaks, and blank blocks at chapter edges;
- write one line per work: its path in the corpus, and a SHA-256 over its chapters' SHA-256s.

The baseline holds hashes only, no text from the corpus. A run compares with the committed baseline. Any difference fails unless `textVersion` changed in the same commit; that is the proof the spec asks for, that a style-only change keeps every chapter's text.

Run Task 17's comparison on a sample of 50 works chosen for coverage: most ruby, most gaiji, most headings, longest, 割り注, 返り点. Record the conversion time of the largest work.

- [ ] **Step 2: Run and commit**

```bash
TEST_RUNNER_AOZORA_CORPUS=$HOME/aozorabunko_text bash scripts/xctest.sh -t 3600 -- -only-testing:'yuedu appTests/AozoraCorpusTests'
git commit -m "test(aozora): convert the whole corpus and pin every chapter's text"
```

## Task 22: Record what landed

Add "Phase 1b: what landed" to this plan, with:
- the commits;
- the corpus numbers: conversions, Readium opens, the parity sample;
- the timings: `aozora.import.convert` and `aozora.regenerate` for the largest work;
- every decision made while implementing.

```bash
git commit -m "docs(aozora): record what Phase 1b landed"
```

## Phase 1b: what landed

2026-10-07. Task 12–13: 9171a1e8. Task 14: 9221d65c. Task 15: b406bb96. Task 16: 878c65f8. Task 17: ad26548b. Tasks 18–19, landed together: 1c9afdf6. Task 20: 2bfeb0cc. Task 21: 4a50ad0a, and a688ab82 for what it found.

Decisions made while implementing:

- **ASCII whitespace (Task 12).** The collapse runs over a block's leaves in order, across inline boundaries. A copied leaf splits around a deleted unit, so the text it keeps stays an identity run; a surviving tab becomes a one-unit replacement. The corpus changed 3,365 units in 139 works, counted as ASCII spaces and tabs in plain-text tokens that no identity run copies. No work shows U+00A0 at all, so Task 17 needs no case for a block holding only U+00A0.
- **Anchors (Task 14).** `h` and the block's index among all spans; a block's second inline heading and later add `-2`, `-3`, ….
- **Parts (Task 14).** A split chapter's parts are titled after the heading that starts it. Text before the first heading has no heading, so its parts take the last heading before them, or the work's title.
- **Figures (Tasks 15–16).** The syntax tree does not tell 写真 from 挿絵, so every figure is an `illustration`. A figure is packaged as `OPS/images/<n>-<its file name, cleaned>`: named after the figure the text names, numbered so two names that clean up alike stay apart.
- **Import (Task 18).** Detection reads a `.txt` off the main actor. A zip without an Aozora text returns nil and falls through to the manga importer. The original is kept as `<epub stem>.aozora.txt` or `.zip`. A failure after the book reached the shelf deletes it with its files.
- **Regeneration (Task 20).** The reader passes its own id to `prepare`, so its own hold on the book does not count as another reader (`ReadingResourceUsage.isInUse(bookID:besides:)`). The reader shows its opening view while `prepare` runs.
- **Ruby BrowserAuto does not lay out (Task 21).** The first corpus parity sample sent three chapters to legacy, and `HorizontalRubySupport` explained both causes. A word with readings on both sides is a ruby inside a ruby, and a ruby over a figure has an `<img>` in its base; BrowserAuto takes neither, nor `rtc`. Such a chapter goes to legacy in both writing modes, with the same text, and the contract records it as its second exception. The corpus holds 82 such chapters in 31 works, and 19 rubies over a figure, all in 黒死館殺人事件 (Hebrew letters). A ruby whose base shows nothing, a figure whose file is missing, is no longer written: it annotates nothing. Task 17's fixture gained a chapter for both cases.
- **Table of contents titles (Task 21).** Readium cleans a navigation label as EPUB asks: every run of white space, U+3000 included, becomes one space, and `PublicationSession.sanitizedTitle` does the same after it. So 「第一部　医学博士…」 is listed as 「第一部 医学博士…」, as in every EPUB; nav.xhtml keeps the planned title, and the corpus test compares under that rule (it was 829 of the first run's 833 problems).
- **Blank headings (Task 21).** A label that is blank after that cleanup is ignored, together with every entry nested under it. Four works set U+3000 alone as a heading (［＃大見出し］　［＃大見出し終わり］), and Readium dropped 4 to 82 entries of each of them. Such a heading still starts its chapter but gets no entry, and the title page gets none when the work's title is blank.
- **Parity (Tasks 17 and 21).** Legacy's text is compared scalar by scalar. A curled quote in it stands for a straight one only where the plan has a straight quote, so a work's own curly quotes are compared as themselves. A failure prints the first difference with its context, not two whole chapters.

Corpus run, 17,158 works, with `TEST_RUNNER_AOZORA_CORPUS` on the iOS 27 simulator:

| Check | Result |
|---|---:|
| Converted, and opened by Readium | 17,158 |
| Chapters | 113,562 |
| Chapter count, table of contents or text off the plan | 0 (first run: 833, see above) |
| Baseline | recorded on the first run; the second matched all 17,158 lines |
| Parity sample, horizontal | 50 works, 194 chapters in 111 s: every text as planned |
| Parity sample, vertical | 50 works, 194 chapters in 136 s: every text as planned |

The baseline, `Tests/iOS/yuedu appTests/Fixtures/aozora-chapter-text-baseline.tsv`, holds one line per work: its folder and the first 16 hex digits of a SHA-256 over its chapters' SHA-256s. Its header names `textVersion` and the corpus commit (0984f7dc), and a run on another checkout says so instead of comparing.

The parity sample takes 50 works round-robin by the most ruby, gaiji, headings, length, 割り注 and 返り点. In each it checks the title page, the first body chapter, the colophon, and the chapter richest in what the work was chosen for. Legacy, BrowserAuto paged and BrowserAuto scroll read every one of them as planned, in both writing modes; the two holding a ruby inside a ruby went to legacy, as the contract now expects.

Timings for the largest work, `50685_ruby_67979` (2.1 MB, 324 chapters), three runs each on the iOS 27 simulator, end to end: conversion on its own 1.44–1.60 s, `LocalBookImportService.importBook` 1.54–1.71 s, `AozoraBookRegenerator.prepare` regenerating it 1.59–1.75 s. One earlier single run measured about twice that (2.5–3.5 s); its cause was not looked into. Converting and opening all 17,158 works took 170 s, `activeProcessorCount` at a time. A device measurement is still to be recorded.

## Phase 1c (outline — automatic migration on first open)

**Skipped for now (maintainer, 2026-10-07).** This is a developer build with no Aozora readers yet, and none expected before a release. What that leaves:
- Two Aozora parsers coexist until step 4: `AozoraMarkupParser` on the TXT path and the new module.
- A TXT Aozora book imported before Phase 1b stays on the TXT path.
- A converter change that changes displayed text, and so `textVersion`, needs this phase's tools first. The regenerator refuses such a change on its own (`.textChanged`, `.olderTextVersion`), so nothing is migrated silently.

1. **Coordinate-space tag, one release first.** Add a coordinate-space id to synced reading positions. New clients ignore remote positions from another space. Confirm that the decoding of `SyncEnvelope<CoreTextReadingPosition>` tolerates the unknown field on old clients.
2. **Inverse projection.** Add the inverse of `displayedOffset(forSourceOffset:)` for the TXT path.
3. **Migration service.** Use the journal order of `TXTReaderIndexMigrationService`: write the journal, then commit bookmarks, then positions, then switch the book record, then delete the journal.
   - Bookmarks map their start and end separately.
   - If any mapping cannot be proven, the book stays on the TXT path and remains readable, with a diagnostic.
   - Positions land in the chapter text of Task 14: BrowserAuto's form. In a chapter that legacy lays out, an offset after a figure lands one unit early per figure before it (Phase 1b's text contract). The migration records that as a known bound, not as a failure.
4. **One parser.** `AozoraMarkupParser` delegates to the new module in a TXT-compatible mode: it strips notes, keeps the kana-reading guard, and does no gaiji, accent or kunojiten conversion. `AozoraTXTTests` pass unchanged.

## Phase 1d (outline — vertical writing for Aozora books)

**Landed 2026-10-07 in f7f9c593**, after the [vertical typography plan](2026-10-06-vertical-typography.md); see "Phase 1d: what landed" below.

The 排版方向 control comes from that plan: a maintainer decision of 2026-10-06, after 5 of 8 Aozora Bunko readers on the App Store were confirmed to offer 縦書き／横書き switching. The other 3 mention only 縦書き. Phase 1d makes a converted book follow it:
- `ReadingBook.allowsVerticalWritingMode` (`Models.swift:871`) is true for a book with `aozora`.
- The writing-mode change handler (`ReaderView.swift:2391`) updates the opening direction for such a book, not only for `!isEPUB`.
- `HomeView.resolveOpeningDirection` (`HomeView.swift:330`) uses the setting for such a book instead of inspecting the EPUB's declared flow.
- `effectiveWritingMode` (`ReaderView+TXTVerticalScroll.swift:142`) needs no change once the first gate is open.
- Rerun Task 17 in vertical writing with the figure exception, and add reader tests for the direction.

### Phase 1d: what landed

- `ReadingBook.allowsVerticalWritingMode` is true for a book with `aozora`, so 閱讀設定 offers 排版方向 and `effectiveWritingMode` follows it.
- `ReadingBook.opensWithDeclaredEPUBFlow` decides whether a book opens as its EPUB declares; `HomeView.resolveOpeningDirection` reads it, and a converted book opens the way the setting lays it out.
- The writing-mode change handler keys on `allowsVerticalWritingMode` alone; `!isEPUB` had been redundant with it.
- Tests: `WritingDirectionVisibilityTests` (offer and opening direction); Task 17 already ran vertical with the figure exception, and the corpus parity sample now runs vertical too.
- Checked on the iOS 27 simulator with 『吾輩は猫である』中篇自序 imported from its text: Writing Direction is offered, and Vertical lays the book out vertically, its ruby on the right.
- Phase 2's capability note on 縦中横 is out of date: since YueduCoreText 0.7.0, BrowserAuto sets supported `text-combine-upright` values in vertical writing itself (`BrowserLayoutCapabilityScanner.declaration`). 横組み (a `writing-mode` other than `vertical-rl`) and a non-default `ruby-position` still send a chapter to legacy.

## Phase 2 (outline)

- **CSS group.** Map 字下げ, 地付き／字上げ, headings, 字級, 太字 and 斜体 in the app stylesheet. Check each mapping in horizontal and vertical writing in both engines. Page breaks are already chapter breaks (Task 14).
- **Capability limits found in Phase 1b.** In vertical writing, BrowserAuto sends a chapter to legacy for `text-combine-upright` (縦中横) and for a `writing-mode` other than `vertical-rl` (横組み): `BrowserLayoutCapabilityScanner.swift:140-146`. It does the same for a non-default `ruby-position` (左にルビ). Each mapping either lands in the browser engine first, or is accepted as a fallback with Task 17 updated to expect it.
- **傍点／傍線.** Show them in both engines (spec decision 5), so a chapter that falls back to the legacy engine keeps them: `text-emphasis` in YueduCoreText, plus an equivalent in the legacy engine.
- **Every Phase 2 change** bumps `converterVersion` only. Task 21's baseline proves the text did not change, and Task 20 regenerates existing books.
