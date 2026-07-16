# EPUB 3 official-sample harness

This harness reproducibly selects, downloads, and scans the official EPUB 3
samples described by `sample-manifest.json`, then optionally exercises them
through Yuedu's production reading pipeline. The recorded sample-level results
are in `compatibility-matrix.md`.

Validate the committed manifest:

```bash
python3 scripts/epub3_samples.py manifest-check
```

Fetch every sample whose binary is not already valid in the local cache:

```bash
python3 scripts/epub3_samples.py fetch
```

Force a verified replacement of one exact sample:

```bash
python3 scripts/epub3_samples.py fetch --sample linear-algebra --force
```

Run the deterministic structural scan across the verified local corpus:

```bash
python3 scripts/epub3_samples.py scan
```

Scan one or more exact samples while developing the harness:

```bash
python3 scripts/epub3_samples.py scan --sample linear-algebra --sample moby-dick
```

## Current-branch corpus capture

Run the opt-in production-pipeline smoke suite after fetching the full corpus.
Keep result bundles and DerivedData under the ignored `.build-week/` tree:

```bash
ROOT=$(git rev-parse --show-toplevel)
CORPUS_DIR="$ROOT/.build-week/epub3-samples/books"
RESULTS_DIR="$ROOT/.build-week/epub3-samples/results"
CAPTURE="current-rerun-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR/derived-data"

TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1 \
TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR="$CORPUS_DIR" \
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -resultBundlePath "$RESULTS_DIR/$CAPTURE.xcresult" \
  -derivedDataPath "$RESULTS_DIR/derived-data/$CAPTURE" \
  -parallel-testing-enabled NO
```

## Baseline corpus capture

The recorded baseline uses production tag `build-week-baseline` (`dd62d80`)
with harness commit `fa95f83`. To reproduce it without introducing later
production changes, create a detached worktree and replay the four harness
commits after harness base `3ab61cd`:

```bash
ROOT=$(git rev-parse --show-toplevel)
CORPUS_DIR="$ROOT/.build-week/epub3-samples/books"
RESULTS_DIR="$ROOT/.build-week/epub3-samples/results"
BASELINE_WT=$(mktemp -d /private/tmp/yuedu-build-week-baseline.XXXXXX)

git worktree add --detach "$BASELINE_WT" build-week-baseline
git -C "$BASELINE_WT" cherry-pick 3ab61cd..fa95f83
```

The final `fa95f83` cherry-pick has exactly two expected modify/delete
conflicts because these Build Week planning documents do not exist at the
baseline tag. Keep both files deleted and continue:

```bash
git -C "$BASELINE_WT" rm \
  docs/superpowers/plans/2026-07-15-idpf-epub3-corpus-harness.md \
  docs/superpowers/specs/2026-07-15-idpf-epub3-compatibility-hardening-design.md
git -C "$BASELINE_WT" cherry-pick --continue
git -C "$BASELINE_WT" diff --name-only dd62d80
```

The final diff inspection must contain only harness, test, documentation, and
ignore files—never renderer production files. The app target also references a
local, ignored `GoogleService-Info.plist`. Copy the current worktree's local
file when it exists, and never stage or commit it:

```bash
if [ -f "$ROOT/GoogleService-Info.plist" ]; then
  cp "$ROOT/GoogleService-Info.plist" "$BASELINE_WT/GoogleService-Info.plist"
  git -C "$BASELINE_WT" check-ignore GoogleService-Info.plist
fi
```

Run the baseline suite from that worktree with its output still directed to the
current repository's ignored results directory:

```bash
CAPTURE="baseline-rerun-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR/derived-data"
cd "$BASELINE_WT"

TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1 \
TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR="$CORPUS_DIR" \
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -resultBundlePath "$RESULTS_DIR/$CAPTURE.xcresult" \
  -derivedDataPath "$RESULTS_DIR/derived-data/$CAPTURE" \
  -parallel-testing-enabled NO
```

Remove the detached worktree after the result bundle has been captured:

```bash
cd "$ROOT"
git worktree remove "$BASELINE_WT"
```

## Recorded result and interpretation

Both captures used an iPhone 17 Pro Max simulator on iOS 27.0. The baseline
enumerated 43 runs with 29 passed, 14 failed, and 0 skipped. At production
commit `df45d95`, the final branch enumerated the same 43 runs with 43 passed,
0 failed, and 0 skipped: all 14 initially failing sample checks now pass. Both
static scans pass all 42 samples. A missing or skipped sample invalidates a
capture regardless of the shell exit status.

The seven committed evidence packages cover TOC dismissal, non-ASCII resource
IRIs, mixed-layout dispatch, MathML attachment quality and safety, English
typography, fixed-layout direct image spines, and the authored static fallback
for unsupported controls-less media. The last result does not claim complete
interactive audio/video support. Each package links a minimal fixture and
focused test. Unvisited representative-book checklist items remain `not-run`;
a package proves only its named failure family. Raw `.xcresult` and UI captures
remain in the ignored results directory.

`xcodebuild` strips the documented `TEST_RUNNER_` prefix when forwarding both
variables to the hosted test process. Without `YUEDU_RUN_EPUB3_CORPUS=1` in
that process, Swift Testing reports this external-corpus suite as disabled.
With the flag enabled, `YUEDU_EPUB3_CORPUS_DIR` is required;
the configuration test checks manifest schema and coverage, verifies all 42
files and SHA256 values, and the parameterized test enumerates all 42 samples.
Failures are compatibility evidence and must not be hidden by weakening the
harness.

The shared scheme runs only the dedicated hosted `IDPFEPUB3CorpusTests` target.
This keeps the external-corpus triage suite independent from unrelated compile
debt in the existing monolithic `yuedu appTests` target while retaining
`@testable` access to the production app module.

Downloaded EPUB binaries live under `.build-week/epub3-samples/books/`.
Generated scan and checksum evidence lives under
`.build-week/epub3-samples/results/`. The repository's top-level `.gitignore`
excludes the entire `.build-week/` tree, so both official EPUB binaries and
generated reports remain local and must not be committed.

License and attribution details are sample-specific; use the committed
manifest as the source of truth.

Passing these checks does not claim complete EPUB 3 support. The scanner checks
package structure, and the smoke suite checks only the designated production
paths and targets. Representative manual validation and focused regression
fixtures are still required before recording a compatibility outcome.
