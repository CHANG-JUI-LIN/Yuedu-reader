# EPUB 3 official-sample harness

This harness reproducibly selects, downloads, and scans the official EPUB 3
samples described by `sample-manifest.json`, then optionally exercises them
through Yuedu's production reading pipeline.

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

Run the opt-in production-pipeline smoke suite after fetching the full corpus:

```bash
TEST_RUNNER_YUEDU_RUN_EPUB3_CORPUS=1 \
TEST_RUNNER_YUEDU_EPUB3_CORPUS_DIR="$PWD/.build-week/epub3-samples/books" \
xcodebuild test -project Yuedu-Reader.xcodeproj \
  -scheme 'Yuedu-Reader EPUB3 Corpus' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'IDPFEPUB3CorpusTests/IDPFEPUB3SampleSmokeTests' \
  -parallel-testing-enabled NO
```

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
