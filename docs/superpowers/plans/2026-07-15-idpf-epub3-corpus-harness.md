# IDPF EPUB 3 Corpus Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible, Git-safe workflow that downloads every official IDPF EPUB 3 sample, performs structural and production-pipeline smoke checks, captures the `build-week-baseline` result, and produces the initial compatibility matrix used to select later fixes.

**Architecture:** A standard-library Python CLI owns manifest validation, atomic downloads, checksum verification, package scanning, and matrix referential checks. Official binaries and generated results remain under ignored `.build-week/`; an opt-in Swift Testing suite in the dedicated hosted `IDPFEPUB3CorpusTests` target reads the committed manifest and exercises `PublicationSession`, `EPUBAttributedStringBuilder`, `CoreTextPaginator`, and `CoreTextChunkSlicer`. Its shared scheme excludes the monolithic `yuedu appTests` target so unrelated legacy compile debt cannot block corpus triage. The harness is committed before renderer fixes so the same harness commit can be applied to a detached baseline worktree.

**Tech Stack:** Python 3 standard library, Swift 6, Swift Testing, Foundation XML/JSON/ZIP APIs, Readium-backed `PublicationSession`, CoreText paginator and chunk slicer, Markdown evidence files.

---

## Execution Order and Scope Gate

Complete this plan before the MathML and English typography plans. Do not implement any sample-specific renderer fix while the matrix is still `not-run`. After the first full scan and representative manual pass, select at least three additional distinct gaps and write one focused implementation plan per gap using the exact failing sample, production files, fixture, and assertion discovered here.

Before Task 1 changes anything, record the parent of the harness commit series in the ignored work area:

```bash
mkdir -p .build-week/epub3-samples/results
git rev-parse HEAD > .build-week/epub3-samples/results/harness-base.txt
```

## File Responsibility Map

- `.gitignore`: excludes all official binaries, extracted trees, raw reports, and temporary baseline worktrees under `.build-week/`.
- `scripts/epub3_samples.py`: CLI entry point plus manifest, download, scan, and matrix-validation logic; no third-party packages.
- `Tests/Tools/test_epub3_samples.py`: fast unit tests for the Python tooling using temporary synthetic EPUB archives.
- `docs/build-week/epub3/sample-manifest.json`: committed catalog metadata, official URLs, checksums, feature tags, probes, and manual checkpoints.
- `docs/build-week/epub3/compatibility-matrix.md`: one row per manifest sample and explicit baseline/current outcomes.
- `docs/build-week/epub3/README.md`: exact fetch, scan, baseline, current-branch, and manual-review commands.
- `docs/build-week/epub3/evidence/README.md`: evidence naming, attribution, screenshot, and commit-link contract.
- `Tests/BuildWeek/IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests.swift`: self-contained opt-in production-pipeline smoke suite for external corpus files; it does not depend on normal-target `EPUBTestFixtures`.
- `Yuedu-Reader.xcodeproj/project.pbxproj`: dedicated hosted `IDPFEPUB3CorpusTests` target, app dependency, and synchronized source group.
- `Yuedu-Reader.xcodeproj/xcshareddata/xcschemes/Yuedu-Reader EPUB3 Corpus.xcscheme`: corpus-only test action with the production app as host.

### Task 1: Define and validate the committed manifest

**Files:**
- Modify: `.gitignore`
- Create: `scripts/epub3_samples.py`
- Create: `Tests/Tools/test_epub3_samples.py`
- Create: `docs/build-week/epub3/sample-manifest.json`

- [ ] **Step 1: Write failing manifest-validation tests**

Create `Tests/Tools/test_epub3_samples.py` with temporary JSON files that prove the validator accepts one complete entry and rejects duplicate IDs, duplicate filenames, non-HTTPS URLs, invalid SHA-256 values, missing license notes, empty feature lists, and manual entries without checkpoints.

```python
import json
import tempfile
import unittest
from pathlib import Path

from scripts.epub3_samples import ManifestError, load_manifest


class ManifestTests(unittest.TestCase):
    def valid_entry(self) -> dict:
        return {
            "id": "linear-algebra",
            "title": "Linear Algebra",
            "source_url": "https://github.com/IDPF/epub3-samples/releases/download/20170606/linear-algebra.epub",
            "catalog_url": "https://idpf.github.io/epub3-samples/30/samples.html#linear-algebra",
            "filename": "linear-algebra.epub",
            "sha256": "a" * 64,
            "license": "GNU FDL 1.2; see official sample metadata",
            "features": ["mathml", "reflowable"],
            "smoke_targets": [{"chapter_index": 0, "text_probes": ["vector"]}],
            "manual": True,
            "manual_checkpoints": ["inline MathML baseline"],
        }

    def write_manifest(self, entries: list[dict]) -> Path:
        root = Path(tempfile.mkdtemp())
        path = root / "manifest.json"
        path.write_text(json.dumps({"schema_version": 1, "samples": entries}), encoding="utf-8")
        return path

    def test_valid_manifest_loads(self):
        manifest = load_manifest(self.write_manifest([self.valid_entry()]))
        self.assertEqual(manifest.samples[0].id, "linear-algebra")

    def test_duplicate_id_is_rejected(self):
        entry = self.valid_entry()
        with self.assertRaisesRegex(ManifestError, "duplicate sample id"):
            load_manifest(self.write_manifest([entry, dict(entry)]))

    def test_non_https_url_is_rejected(self):
        entry = self.valid_entry()
        entry["source_url"] = "http://example.com/sample.epub"
        with self.assertRaisesRegex(ManifestError, "HTTPS"):
            load_manifest(self.write_manifest([entry]))
```

- [ ] **Step 2: Run the Python RED test**

Run:

```bash
python3 -m unittest discover -s Tests/Tools -p 'test_epub3_samples.py' -v
```

Expected: import failure because `scripts/epub3_samples.py` does not exist.

- [ ] **Step 3: Implement manifest dataclasses and validation**

Create `scripts/epub3_samples.py` with immutable `SmokeTarget`, `Sample`, and `Manifest` dataclasses, `ManifestError`, `load_manifest(path)`, and `validate_manifest(manifest)`. Normalize no values silently: malformed input must name the sample ID and field. Validate `sha256` with `re.fullmatch(r"[0-9a-f]{64}", value)` and require exactly eight `manual: true` entries.

```python
@dataclass(frozen=True)
class SmokeTarget:
    chapter_index: int | None
    spine_href: str | None
    text_probes: tuple[str, ...]
    expects_image_page: bool = False
    expects_fallback: bool = False


@dataclass(frozen=True)
class Sample:
    id: str
    title: str
    source_url: str
    catalog_url: str
    filename: str
    sha256: str
    license: str
    features: tuple[str, ...]
    smoke_targets: tuple[SmokeTarget, ...]
    manual: bool
    manual_checkpoints: tuple[str, ...]
```

Add `.build-week/` to `.gitignore`. Populate `sample-manifest.json` from every downloadable row and variant on the official catalog. Bootstrap each checksum from the official release asset before staging the manifest. Mark exactly these eight manual samples: Linear Algebra, Moby Dick, The Waste Land with OTF fonts, Children's Literature, Accessible EPUB 3, Israel Sailing, Kusamakura, and Page Blanche.

- [ ] **Step 4: Run GREEN validation**

Run:

```bash
python3 -m unittest discover -s Tests/Tools -p 'test_epub3_samples.py' -v
python3 scripts/epub3_samples.py manifest-check
git diff --check
```

Expected: all Python tests pass; the CLI reports the total manifest count and `manual=8`; diff check is silent.

- [ ] **Step 5: Commit the schema and complete catalog**

```bash
git add .gitignore scripts/epub3_samples.py Tests/Tools/test_epub3_samples.py \
  docs/build-week/epub3/sample-manifest.json
git commit -m "test: define official EPUB 3 sample corpus"
```

### Task 2: Add atomic download and checksum enforcement

**Files:**
- Modify: `scripts/epub3_samples.py`
- Modify: `Tests/Tools/test_epub3_samples.py`
- Create: `docs/build-week/epub3/README.md`

- [ ] **Step 1: Write failing downloader tests**

Use a local `http.server.ThreadingHTTPServer` in the test process. Cover successful download, valid cache reuse, checksum mismatch, a non-ZIP response, interrupted `.part` cleanup, and continuing to later samples after one failure. Assert that only a verified file is atomically moved to `books/<filename>`.

```python
def test_checksum_mismatch_never_replaces_cached_book(self):
    cached = self.books / "sample.epub"
    cached.write_bytes(self.valid_epub)
    result = fetch_sample(self.sample(sha256="0" * 64), self.books, opener=self.opener)
    self.assertFalse(result.ok)
    self.assertEqual(cached.read_bytes(), self.valid_epub)
    self.assertFalse((self.books / "sample.epub.part").exists())
```

- [ ] **Step 2: Run RED**

Run the same `unittest discover` command. Expected: `fetch_sample` is undefined.

- [ ] **Step 3: Implement `fetch`**

Add `sha256_file`, `has_zip_signature`, `fetch_sample`, and `fetch_all`. Use `urllib.request`, a temporary `.part` file, 60-second timeout, `os.replace`, and a `FetchResult` record. A valid cached file returns `cached`; `--force` redownloads. Attempt every requested entry and return exit code 1 if any result is not `downloaded` or `cached`.

Document exact commands:

```bash
python3 scripts/epub3_samples.py fetch
python3 scripts/epub3_samples.py fetch --sample linear-algebra --force
```

- [ ] **Step 4: Run GREEN and inspect ignored output**

Run Python tests, then `fetch --sample linear-algebra`. Expected: a checksum-verified EPUB at `.build-week/epub3-samples/books/linear-algebra.epub`; `git status --short --ignored` shows the directory as ignored.

- [ ] **Step 5: Commit downloader and workflow docs**

```bash
git add scripts/epub3_samples.py Tests/Tools/test_epub3_samples.py docs/build-week/epub3/README.md
git commit -m "test: download official EPUB samples reproducibly"
```

### Task 3: Add structural package scanning

**Files:**
- Modify: `scripts/epub3_samples.py`
- Modify: `Tests/Tools/test_epub3_samples.py`

- [ ] **Step 1: Write failing scanner tests**

Generate tiny EPUB ZIPs in memory. Cover stored-first `mimetype`, container rootfile discovery, OPF manifest/spine/nav references, missing resources, duplicate manifest IDs, path traversal, MathML/Ruby/SMIL/SVG/fixed-layout/RTL/vertical/bindings feature detection, and aggregate reporting.

```python
def test_scan_reports_missing_spine_resource(self):
    result = scan_epub(self.write_epub(opf_with_missing_spine_item()))
    self.assertIn("missing spine resource: OPS/chapter.xhtml", result.errors)
    self.assertEqual(result.status, "fail")
```

- [ ] **Step 2: Run RED**

Expected: `scan_epub` is undefined.

- [ ] **Step 3: Implement `scan`**

Use `zipfile.ZipFile` and `xml.etree.ElementTree`. Reject absolute paths, `..` components, and normalized-name collisions. Produce one `ScanResult` per manifest sample containing package facts, detected features, warnings, errors, and `status`. Write a stable sorted JSON report to `.build-week/epub3-samples/results/scan-results.json` even when some samples fail.

- [ ] **Step 4: Run GREEN and full static scan**

Run:

```bash
python3 -m unittest discover -s Tests/Tools -p 'test_epub3_samples.py' -v
python3 scripts/epub3_samples.py scan
```

Expected: unit tests pass; every manifest ID appears once in the JSON report; the CLI exits nonzero only if a requested book is absent/corrupt or has structural errors.

- [ ] **Step 5: Commit scanner**

```bash
git add scripts/epub3_samples.py Tests/Tools/test_epub3_samples.py
git commit -m "test: scan official EPUB sample packages"
```

### Task 4: Add opt-in production-pipeline smoke tests

**Files:**
- Create: `Tests/BuildWeek/IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests.swift`
- Modify: `Yuedu-Reader.xcodeproj/project.pbxproj`
- Create: `Yuedu-Reader.xcodeproj/xcshareddata/xcschemes/Yuedu-Reader EPUB3 Corpus.xcscheme`
- Modify: `docs/build-week/epub3/README.md`
- Modify: `docs/build-week/epub3/sample-manifest.json`
- Modify: `docs/superpowers/specs/2026-07-15-idpf-epub3-compatibility-hardening-design.md`

- [ ] **Step 1: Write the opt-in test loader and failing assertions**

Define Codable manifest types and a minimal `ReaderRenderSettings` helper inside the test file, without importing normal-target `EPUBTestFixtures`. `isEnabled` reads `YUEDU_RUN_EPUB3_CORPUS`; when disabled, use Swift Testing's runtime skip. When enabled, require `YUEDU_EPUB3_CORPUS_DIR`, verify every checksum, and parameterize over all samples. Resolve each smoke target by `spine_href` first, then `chapter_index`.

```swift
@Suite("Official IDPF EPUB 3 corpus", .serialized)
struct IDPFEPUB3SampleSmokeTests {
    @Test("corpus configuration")
    func corpusConfiguration() throws {
        try Corpus.requireEnabled()
    }

    @Test("sample opens, renders, paginates, and slices", arguments: Corpus.loadCasesFromEnvironment())
    @MainActor
    func smoke(sample: Corpus.Sample) async throws {
        try Corpus.requireEnabled()
        let url = try Corpus.verifiedBookURL(for: sample)
        let session = try await PublicationSession.open(sourceURL: url)
        #expect(!session.chapters.isEmpty)

        for target in sample.smokeTargets {
            let index = try target.resolveChapter(in: session)
            let result = try await EPUBAttributedStringBuilder(
                session: session,
                renderSize: CGSize(width: 390, height: 844)
            ).buildChapter(
                at: index,
                settings: makeRenderSettings(writingMode: .horizontal),
                themeTextColor: .black,
                themeBackgroundColor: .white
            )
            try target.assertVisibleOutput(result)
            try await target.assertPagedAndScrollSmoke(result, chapterIndex: index)
        }
    }
}
```

`Corpus.loadCasesFromEnvironment()` is nonthrowing: it returns `[]` while the suite is disabled, but records an issue and returns `[]` when the suite is enabled and configuration is invalid. The separate configuration test therefore reports a runtime skip instead of silently passing when disabled. The test-local `makeRenderSettings` helper constructs only the production `ReaderRenderSettings` values needed by the harness. `assertPagedAndScrollSmoke` calls `CoreTextPaginator.paginate` with the result's image/background/anchors and asserts nonempty in-bounds `pageRanges`. Page ranges must cover the attributed string continuously except for ranges whose every UTF-16 location carries the production `HTMLAttributedStringBuilder.pageBreakAttribute`; no other gap or any overlap is allowed. For reflowable samples it calls `CoreTextChunkSlicer.slice` and asserts continuous chunk ranges ending at the attributed-string length. Fixed-layout/image-in-spine targets assert `imagePage` or the fixed-layout capability path instead of forcing reflow.

- [ ] **Step 2: Ask the user to run the RED corpus suite**

```bash
TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1 \
TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR="$PWD/.build-week/epub3-samples/books" \
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -parallel-testing-enabled NO
```

Expected: individual sample failures reveal the initial production compatibility gaps; the suite itself must compile and enumerate every manifest sample.

- [ ] **Step 3: Fix only harness defects**

Correct manifest target selection or test capability branching if the harness misclassifies a valid path. Do not change production renderer behavior in this task. A production failure remains failing evidence.

- [ ] **Step 4: Re-run fast checks and have the user rerun the suite**

Run `xcrun swiftc -parse Tests/BuildWeek/IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests.swift`, Python tests, `manifest-check`, and `git diff --check`. Run the same dedicated-scheme `xcodebuild` command. Expected: the isolated harness target compiles without building `yuedu appTests`; production failures remain accurately reported.

- [ ] **Step 5: Commit the harness before any renderer fix**

```bash
git add 'Tests/BuildWeek/IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests.swift' \
  Yuedu-Reader.xcodeproj/project.pbxproj \
  'Yuedu-Reader.xcodeproj/xcshareddata/xcschemes/Yuedu-Reader EPUB3 Corpus.xcscheme' \
  docs/build-week/epub3/README.md \
  docs/build-week/epub3/sample-manifest.json \
  docs/superpowers/specs/2026-07-15-idpf-epub3-compatibility-hardening-design.md \
  docs/superpowers/plans/2026-07-15-idpf-epub3-corpus-harness.md
git commit -m "test: smoke test official EPUB samples"
```

Record this commit hash as `HARNESS_COMMIT` in the matrix README.

### Task 5: Capture the baseline and current matrices

**Files:**
- Create: `docs/build-week/epub3/compatibility-matrix.md`
- Modify: `docs/build-week/epub3/README.md`

- [ ] **Step 1: Create the matrix with one row per manifest sample**

Use columns: sample, features, baseline static/open/render/paged/scroll/manual, current static/open/render/paged/scroll/manual, final outcome, issue/evidence/test/commit. Initialize unobserved cells to `not-run`; never leave cells blank.

- [ ] **Step 2: Prepare a detached baseline worktree**

```bash
HARNESS_BASE=$(cat .build-week/epub3-samples/results/harness-base.txt)
HARNESS_COMMIT=$(git rev-parse HEAD)
BASELINE_WT=$(mktemp -d /tmp/yuedu-build-week-baseline.XXXXXX)
git worktree add --detach "$BASELINE_WT" build-week-baseline
git -C "$BASELINE_WT" cherry-pick "$HARNESS_BASE..$HARNESS_COMMIT"
```

Expected: the detached worktree starts at `dd62d80`; every commit after `HARNESS_BASE` through `HARNESS_COMMIT` is replayed in order, and `git -C "$BASELINE_WT" diff --name-only build-week-baseline..HEAD` contains only harness/tests/docs and `.gitignore`, never renderer production files.

- [ ] **Step 3: Give the user the exact baseline test command**

```bash
CORPUS_DIR="$PWD/.build-week/epub3-samples/books"
cd "$BASELINE_WT"
TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1 \
TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR="$CORPUS_DIR" \
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -parallel-testing-enabled NO
```

Expected: a sample-scoped baseline report. Record failures honestly; do not fix them in the baseline worktree.

- [ ] **Step 4: Run the current-branch suite and update both matrix halves**

Return to `codex/openai-build-week`, have the user run the same command against the current worktree, and record baseline/current results plus sample checksum and harness commit. Remove the temporary worktree only after results are captured:

```bash
git worktree remove "$BASELINE_WT"
```

- [ ] **Step 5: Commit the initial matrix**

```bash
git add docs/build-week/epub3/compatibility-matrix.md docs/build-week/epub3/README.md
git commit -m "docs: record EPUB 3 compatibility baseline"
```

### Task 6: Add evidence rules and select follow-up gaps

**Files:**
- Create: `docs/build-week/epub3/evidence/README.md`
- Create: `docs/build-week/epub3/gap-ranking.md`
- Modify: `scripts/epub3_samples.py`
- Modify: `Tests/Tools/test_epub3_samples.py`

- [ ] **Step 1: Write failing matrix/evidence integrity tests**

Test that `matrix-check` requires every manifest ID exactly once, allows only the six design outcomes, rejects `build-week-fixed` without an issue/test/commit link, and verifies every evidence directory named in the matrix exists.

- [ ] **Step 2: Implement `matrix-check` and evidence conventions**

Evidence IDs match `BW-EPUB3-[0-9]{3}`. Each evidence directory contains `README.md`, `before.png`, and `after.png`; README fields include sample/checkpoint, sample checksum, baseline commit, after commit, fixture, test command, device/iOS/settings, expected/observed behavior, and license attribution when official content is visible.

- [ ] **Step 3: Rank observed failures**

Create `gap-ranking.md` with one row per failing/partial sample. Score severity (0–3), reading reach (0–3), demonstration value (0–2), and fixture feasibility (0–2). Select the highest-scoring three distinct failure families after excluding MathML, English typography, pre-existing support, and out-of-scope full interactive systems.

- [ ] **Step 4: Create one exact follow-up plan per selected gap**

For each selected row, inspect its failing code path first, then write a plan naming the production file, new `EPUBTestFixtures` extension, failing assertion, focused user-run test command, evidence ID, and commit message. Do not begin its code change until that focused plan passes the writing-plans self-review.

- [ ] **Step 5: Verify and commit triage artifacts**

```bash
python3 -m unittest discover -s Tests/Tools -p 'test_epub3_samples.py' -v
python3 scripts/epub3_samples.py matrix-check
git diff --check
git add scripts/epub3_samples.py Tests/Tools/test_epub3_samples.py \
  docs/build-week/epub3/evidence/README.md docs/build-week/epub3/gap-ranking.md
git commit -m "docs: rank official EPUB compatibility gaps"
```

## Completion Gate

This plan is complete when the corpus is fully represented, fetched files are checksum-verified and ignored, static and production smoke results exist for baseline/current, the eight manual books have explicit checkpoints, and the three additional gap plans name actual observed failures. It is not complete merely because the downloader works.
