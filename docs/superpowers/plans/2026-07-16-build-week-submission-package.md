# OpenAI Build Week Submission Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `codex/openai-build-week` judge-ready with an English root README, reusable Devpost submission copy, and a sub-three-minute narrated demo script.

**Architecture:** Keep the existing product README as the repository entry point, but move verified Build Week results and reproduction instructions near the top. Store Devpost form copy and the timed video script as separate focused documents under `docs/build-week/`, sourcing all technical claims from the committed compatibility matrix and evidence packages.

**Tech Stack:** Markdown, Git, Python 3 manifest/matrix validators, Xcode shared schemes, GitHub branch links.

---

## File Map

- Modify `README.md`: durable public product overview plus judge-facing Build Week results, scope boundary, Codex/GPT-5.6 workflow, and reproduction commands.
- Create `docs/build-week/devpost-submission.md`: copy-ready Devpost title, tagline, category, description, technology list, judge notes, and required-field checklist.
- Create `docs/build-week/demo-script.md`: 2:30–2:50 English demo timeline with exact on-screen actions and voiceover.

No application, test, Xcode project, or generated corpus files change.

### Task 1: Make the branch README judge-ready

**Files:**
- Modify: `README.md:1-100`
- Reference: `docs/build-week/epub3/compatibility-matrix.md`
- Reference: `docs/build-week/epub3/evidence/README.md`

- [ ] **Step 1: Confirm branch and clean starting state**

Run:

```bash
test "$(git branch --show-current)" = "codex/openai-build-week"
git status --short
```

Expected: the branch assertion exits 0 and `git status --short` prints nothing.

- [ ] **Step 2: Update the hero positioning**

Keep the icon, language links, distribution badges, and existing article link. Change the centered one-line description to:

```html
<p align="center">
  Premium native reading, without ecosystem lock-in.
</p>
```

Add this supporting sentence directly below the badges and before the existing featured-article quote:

```markdown
> **Your books. Your sources. Your reading experience.** Yuedu is a native iOS reader for local files, open catalogs, self-hosted libraries, feeds, and user-chosen content sources.
```

- [ ] **Step 3: Add the Build Week result block**

Insert this section after the featured-article quote and before `## Features`:

```markdown
## OpenAI Build Week 2026

During Build Week, Codex with GPT-5.6 helped turn the official IDPF EPUB 3 Samples into a reproducible compatibility program for Yuedu's production CoreText reader.

| Capture | Production revision | Official smoke result |
|:--|:--|:--|
| Before | `build-week-baseline` / `dd62d80` | 29 passed · 14 failed · 0 skipped |
| After | `df45d95` | **43 passed · 0 failed · 0 skipped** |

The corpus contains 42 official sample EPUBs and 43 designated checks. Passing them is bounded compatibility evidence, not a claim of complete EPUB 3 support.

- [Compatibility matrix](docs/build-week/epub3/compatibility-matrix.md)
- [Seven before/after evidence packages](docs/build-week/epub3/evidence/)
- [Reproducible corpus harness](docs/build-week/epub3/README.md)
```

- [ ] **Step 4: Add verified change and baseline-boundary sections**

Insert these sections after `## Features` and its table:

```markdown
## What changed during Build Week

- Built a checksum-pinned manifest, safe batch downloader, structural scanner, and opt-in production-pipeline smoke suite for all official downloadable samples.
- Fixed non-ASCII EPUB resource IRIs and reliable table-of-contents navigation.
- Routed mixed-layout spine items correctly and restored fixed-layout resource and direct-image pages.
- Improved MathML attachment sizing, baseline alignment, raster clarity, fallback safety, and complex table handling.
- Added language-aware English hyphenation, soft-hyphen handling, and eligible line justification.
- Preserved authored static fallback text when controls-less media cannot surface a native player.

Every claimed repair links a minimal synthetic fixture, focused automated test, implementation commit, matrix row, and before/after evidence package.

## Existing capabilities, not Build Week additions

Yuedu already had its native CoreText reader and support for EPUB CFI, MathML conversion, Ruby, fixed layout, Media Overlay, audio/video, RTL/Bidi, PLS/SSML, vertical writing, TTS synchronization, and text selection before the event baseline. Build Week hardened selected compatibility paths; it did not create those capabilities from scratch.
```

- [ ] **Step 5: Add Codex workflow and exact reproduction commands**

Insert these sections before the existing `## Build` section:

```markdown
## How Codex and GPT-5.6 accelerated the work

Codex helped inspect the native reader pipeline, design the official-sample harness, rank observed failures, reduce each production defect into a small EPUB fixture, and work through red-green regression tests. It also drove exact before/after capture, result-bundle verification, and consistency checks across the manifest, evidence packages, commits, and compatibility matrix.

The implementation stayed in the production renderer. No demo-only renderer or committed copy of the official EPUB corpus was introduced.

## Reproduce the Build Week results

Validate and download the checksum-pinned external corpus:

```bash
python3 scripts/epub3_samples.py manifest-check
python3 scripts/epub3_samples.py fetch
python3 scripts/epub3_samples.py scan
python3 scripts/epub3_samples.py matrix-check
```

Run the focused regression suites for the seven evidenced repair families:

```bash
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderTOCSelectionTimingTests' \
  -only-testing:'yuedu appTests/EPUBResourceIRITests' \
  -only-testing:'yuedu appTests/EPUBMixedLayoutRoutingTests' \
  -only-testing:'yuedu appTests/EPUBFixedImageSpineTests' \
  -only-testing:'yuedu appTests/MathMLBaselineTests' \
  -only-testing:'yuedu appTests/EnglishEPUBTypographyTests' \
  -only-testing:'yuedu appTests/EPUBMediaFallbackTests' \
  -parallel-testing-enabled NO
```

Run all 42 official samples through the dedicated production-pipeline suite:

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

The downloaded EPUB files and generated results remain under the Git-ignored `.build-week/` directory.
```

- [ ] **Step 6: Validate README links and claims**

Run:

```bash
python3 scripts/epub3_samples.py manifest-check
python3 scripts/epub3_samples.py matrix-check
python3 - <<'PY'
from pathlib import Path
import re

root = Path.cwd()
text = (root / "README.md").read_text()
missing = []
for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
    if "://" in target or target.startswith("#"):
        continue
    path = target.split("#", 1)[0]
    if path and not (root / path).exists():
        missing.append(path)
assert not missing, f"Missing README links: {missing}"
print("README local links OK")
PY
git diff --check
```

Expected:

```text
manifest OK: total=42 manual=8 automated=34
matrix OK: samples=42 evidence=7
README local links OK
```

- [ ] **Step 7: Commit the README**

```bash
git add README.md
git commit -m "docs: present Build Week compatibility results"
```

### Task 2: Create copy-ready Devpost content

**Files:**
- Create: `docs/build-week/devpost-submission.md`
- Reference: `README.md`
- Reference: `docs/build-week/epub3/gap-ranking.md`

- [ ] **Step 1: Create the submission metadata and technology list**

Start the document with these exact values:

```markdown
# Devpost Submission Copy — Yuedu Reader

## Project

- **Name:** Yuedu Reader
- **Tagline:** Premium native reading, without ecosystem lock-in.
- **Category:** Apps for Your Life
- **Repository:** https://github.com/CHANG-JUI-LIN/Yuedu-reader/tree/codex/openai-build-week
- **Built with:** Swift, SwiftUI, CoreText, Readium, Python, XCTest, Swift Testing, Codex, GPT-5.6
```

- [ ] **Step 2: Write the public description around the judging criteria**

Use these headings and claims:

```markdown
## Inspiration

Digital reading should not force people to choose between polished typography and control over their own library. Yuedu combines a high-quality native iOS reading experience with user-owned books, open catalogs, self-hosted libraries, feeds, and user-chosen content sources.

## What it does

Yuedu imports EPUB, TXT, CBZ, and ZIP content and connects to sources including RSS, OPDS, WebDAV, browser conversion, local-network import, and compatible book-source rules. Its reading surface is rendered natively with CoreText for precise pagination, CJK vertical writing, synchronized TTS, selection, and advanced layout control.

## What we built during OpenAI Build Week

We used the official IDPF EPUB 3 Samples to replace broad compatibility claims with reproducible evidence. The new workflow pins all 42 downloadable samples by checksum, downloads them outside Git, structurally scans each package, and runs 43 designated checks through Yuedu's production reading paths.

The event baseline passed 29 of 43 checks. The final production revision passes all 43 with no failures or skips. The work fixed non-ASCII resource loading, reliable TOC navigation, mixed and fixed-layout routing, direct image spine rendering, MathML attachment quality and safety, language-aware English typography, and authored fallback preservation for unsupported controls-less media.

## How we built it

Codex with GPT-5.6 helped map the existing CoreText pipeline, design the corpus harness, rank real failures, and reduce each selected defect into a minimal synthetic EPUB fixture. Each repair followed a red-green regression loop and received an implementation commit, focused test, compatibility-matrix entry, and durable before/after evidence.

The fixes stay in the production renderer. Official sample binaries and generated result bundles remain in a Git-ignored directory.

## Challenges

The hardest part was separating genuine product failures from harness limitations across reflowable, fixed-layout, mixed-layout, vertical, media, and mathematical content. Another challenge was improving compatibility without presenting pre-existing features as new work or expanding a one-week scope into a claim of complete EPUB 3 support.

## Accomplishments

- 42 official sample EPUBs represented in a checksum-verified manifest.
- 43/43 designated production smoke checks passing, up from 29/43.
- Seven committed before/after evidence packages.
- Minimal fixtures and focused automated regression tests for every claimed repair family.
- Safe fallback behavior: unsupported content does not crash, erase surrounding body text, or silently discard authored static fallback.

## What we learned

Format support is more credible as a maintained compatibility program than as a checkbox. Official samples expose interactions that isolated unit tests miss, while minimized fixtures turn those discoveries into fast, durable regression protection.

## What's next

Keep the corpus workflow as a release-quality gate, expand representative manual review, and address additional EPUB features only when a sample, fixture, and measurable production behavior justify the claim.
```

- [ ] **Step 3: Add private judge notes and the remaining submission checklist**

Append:

```markdown
## Judge testing notes

1. Open the public Build Week branch linked above.
2. Follow `README.md` to validate the manifest and download the external official corpus.
3. Run the `Yuedu-Reader EPUB3 Corpus` scheme on an iPhone 17 Pro Max simulator.
4. Review `docs/build-week/epub3/compatibility-matrix.md` and the seven linked evidence packages.

No account or hosted service credentials are required for the compatibility harness.

## Values the submitter must provide in Devpost

- Submitter type: choose the truthful Devpost option.
- Country of residence: choose the truthful Devpost option.
- Demo video: provide the final public YouTube URL.
- `/feedback` Session ID: provide the ID returned by the Codex task where most of the work occurred.
- Confirm the branch is pushed and publicly readable before submitting.
```

- [ ] **Step 4: Verify the document contains no invented user-owned values**

Run:

```bash
rg -n 'TBD|TODO|example\.com|youtube\.com/watch\?v=|Session ID: [0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' docs/build-week/devpost-submission.md
git diff --check
```

Expected: `rg` prints no matches and exits 1; `git diff --check` exits 0.

- [ ] **Step 5: Commit the Devpost copy**

```bash
git add docs/build-week/devpost-submission.md
git commit -m "docs: draft Devpost submission copy"
```

### Task 3: Create the timed three-minute demo script

**Files:**
- Create: `docs/build-week/demo-script.md`
- Reference: `docs/build-week/epub3/evidence/BW-EPUB3-004/`
- Reference: `docs/build-week/epub3/evidence/BW-EPUB3-005/`
- Reference: `docs/build-week/epub3/evidence/BW-EPUB3-007/`

- [ ] **Step 1: Create the recording contract and shot list**

Start with:

```markdown
# OpenAI Build Week Demo Script — Yuedu Reader

**Target length:** 2:30–2:50  
**Format:** Public YouTube video, English voiceover, application and repository capture  
**Core claim:** Premium native reading without ecosystem lock-in, strengthened by a reproducible official EPUB 3 compatibility program.

## Recording rules

- Keep the final upload under three minutes.
- Use spoken narration; music-only or caption-only capture is not sufficient.
- Show the app working before showing repository evidence.
- Label pre-existing product capabilities as context, not Build Week additions.
- Do not say “complete EPUB 3 support.” Say “all 43 designated checks pass.”
- Mention both Codex and GPT-5.6 in the narration.
```

- [ ] **Step 2: Add five timed segments with exact narration**

Use this timeline and voiceover:

```markdown
## 0:00–0:25 — The product promise

**On screen:** Yuedu library, open a locally imported EPUB, then show a polished native page.

<!-- VOICEOVER-START -->
> Digital reading usually asks us to choose: polished typography, or control over our books and sources. Yuedu Reader is an open-source native iOS reader built around a different promise: premium native reading, without ecosystem lock-in. Your books, your sources, your reading experience.

## 0:25–0:50 — Existing product context

**On screen:** Brief cuts of vertical writing, an OPDS or WebDAV entry, RSS, and the manga reader. Add an overlay: “Existing before Build Week.”

> Yuedu already imported local books and comics, connected to open catalogs, self-hosted libraries, feeds, and content sources, and rendered reading pages with CoreText instead of a WebView. Build Week did not create those features. It focused on making EPUB compatibility measurable and better.

## 0:50–1:20 — The Build Week method

**On screen:** Official IDPF sample catalog, `sample-manifest.json`, the fetch command, and the compatibility matrix baseline summary.

> With Codex and GPT-5.6, I turned the official IDPF EPUB 3 Samples into a reproducible compatibility program. Forty-two official books are pinned by checksum, downloaded outside Git, structurally scanned, and sent through Yuedu's production reading pipeline. At the event baseline, twenty-nine of forty-three designated checks passed, and fourteen failed.

## 1:20–2:15 — Verified before and after

**On screen:** Fast paired evidence from MathML, English typography, mixed or fixed layout, and media fallback. Show test filenames beside the images.

> Codex helped trace those failures through the existing CoreText architecture, rank their impact, and reduce each selected defect into a minimal EPUB fixture. Red-green tests then protected the production fixes. MathML gained safer fallback, better baseline and sizing, sharper raster output, and robust table formulas. English EPUBs gained language-aware hyphenation and eligible justification. Resource loading, table-of-contents navigation, mixed and fixed-layout routing, direct image pages, and authored media fallback were repaired without adding a demo-only renderer.

## 2:15–2:45 — Result and boundary

**On screen:** Final matrix summary, 43 passed / 0 failed / 0 skipped, then the seven evidence folders and Yuedu closing screen.

> The same suite now passes all forty-three checks with zero failures and zero skips. Every claimed repair links a commit, a minimal fixture, an automated test, a matrix row, and before-and-after evidence. This is not a claim of complete EPUB 3 support. It is a repeatable way to improve compatibility honestly, while keeping the reading experience native and the user's library free.
<!-- VOICEOVER-END -->
```

- [ ] **Step 3: Add capture and upload checklist**

Append:

```markdown
## Capture checklist

- Record app scenes in portrait on the same iPhone simulator where practical.
- Use the committed evidence PNGs directly; do not reconstruct or retouch book content.
- Keep official-sample license attribution in the repository evidence package.
- Show `29 / 43` and `43 / 43` long enough to read.
- Verify the public YouTube setting after upload.
- Listen once with the screen hidden; the narration must still explain the product, Codex, GPT-5.6, and the measured result.
```

- [ ] **Step 4: Verify narration length and forbidden claims**

Run:

```bash
python3 - <<'PY'
from pathlib import Path

text = Path("docs/build-week/demo-script.md").read_text()
voice = text.split("<!-- VOICEOVER-START -->", 1)[1].split("<!-- VOICEOVER-END -->", 1)[0]
words = len(voice.replace(">", " ").split())
assert 320 <= words <= 390, words
assert "complete EPUB 3 support" in text
assert "all forty-three checks" in voice
assert "Codex" in voice and "GPT-5.6" in voice
print(f"voiceover words OK: {words}")
PY
git diff --check
```

Expected: the word count is between 320 and 390 and both commands exit 0.

- [ ] **Step 5: Commit the demo script**

```bash
git add docs/build-week/demo-script.md
git commit -m "docs: script Build Week demo video"
```

### Task 4: Final package verification

**Files:**
- Verify: `README.md`
- Verify: `docs/build-week/devpost-submission.md`
- Verify: `docs/build-week/demo-script.md`

- [ ] **Step 1: Run all documentation and evidence checks**

Run:

```bash
python3 scripts/epub3_samples.py manifest-check
python3 scripts/epub3_samples.py matrix-check
git diff --check
git status --short
```

Expected:

```text
manifest OK: total=42 manual=8 automated=34
matrix OK: samples=42 evidence=7
```

`git diff --check` and `git status --short` must print nothing.

- [ ] **Step 2: Audit the final branch diff and scope**

Run:

```bash
git diff --stat 77a3dea..HEAD -- README.md docs/build-week/devpost-submission.md docs/build-week/demo-script.md
git diff --name-only 77a3dea..HEAD -- README.md docs/build-week/devpost-submission.md docs/build-week/demo-script.md
rg -n 'complete EPUB 3 support|29/43|43/43|GPT-5\.6|Codex' README.md docs/build-week/devpost-submission.md docs/build-week/demo-script.md
```

Expected changed implementation files:

```text
README.md
docs/build-week/demo-script.md
docs/build-week/devpost-submission.md
```

Every occurrence of “complete EPUB 3 support” must negate that claim. The result counts and Codex/GPT-5.6 disclosure must be consistent across all three documents.

- [ ] **Step 3: Report user-owned submission actions**

The handoff must state that the user still needs to provide or approve:

```text
1. Submitter type
2. Country of residence
3. /feedback Session ID
4. Public YouTube URL
5. Push codex/openai-build-week
6. Final Devpost submission
```

Do not push or mutate the Devpost project unless the user explicitly requests it.
