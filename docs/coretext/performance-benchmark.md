# CoreText Performance Benchmark

This note defines the repeatable baseline for CoreText performance work. It is
the implementation companion to
[dtcoretext-performance-and-open-source-plan.md](dtcoretext-performance-and-open-source-plan.md).

## Trace Contract

`ReaderPerfTrace` emits Points of Interest signposts with:

- subsystem: the active app/test bundle identifier;
- category: `ReaderPerformance`;
- interval name: a stable `ReaderPerfStage.rawValue`.

Metadata is deliberately bounded and content-free. It may contain resource
fixture IDs, spine indexes, counts, writing mode, cache result, executor, and
generation. Never add book titles, chapter text, URLs, search queries, or other
user content.

The first instrumentation slice emits:

```text
chapter.load
html.parse
css.collect
css.parse
css.match
ast.build
ir.convert
attributed.render
resource.image.load
layout.fingerprint
layout.vertical.prepare
layout.framesetter.create
layout.pageRanges
layout.displayList
layout.firstPage.publish
render.page
render.chunk
cache.layout
```

`css.match` is nested inside `ast.build`: the current builder resolves each
element's cascade while it constructs the Styled AST. The overlap is
intentional and makes the existing coupling visible until those concerns are
separated.

These names are reserved but will only emit after the corresponding renderer or
cache exists:

```text
resource.image.decode
render.tile
cache.document
cache.raster
```

Keep `ReaderPerfStage.rawValue`, `signpostName`, this document, and
`ReaderPerfTraceTests` synchronized. Renaming a stage breaks saved Instruments
filters and future `XCTOSSignpostMetric` baselines.

## Synthetic Corpus

`CoreTextPerformanceFixtures` generates all corpus data in the test target; no
copyrighted book or network request is required.

| ID | Scale | Primary stage |
| --- | --- | --- |
| `plain-10k` | 10,240+ text characters | fixed overhead, first paint |
| `plain-100k` | 102,400+ text characters | fingerprint, pagination, memory |
| `css-heavy-50k` | 1,000 elements, 300 rules | CSS matching and allocation |
| `image-40` | 40 local image references | resource load/decode/prefetch |
| `vertical-cjk-50k` | 50K+ CJK, ruby, punctuation, Latin | vertical normalization/layout |
| `mixed-epub` | float, table, MathML, SVG, footnote | display-list parity |
| `online-latency` | 8 resources, declared 50 ms fake latency | load dedup/cancellation |

Fixture tests validate identifiers, minimum scale, CSS/image counts, and that
resource attributes do not point at public network URLs.

## Large Real-World EPUB Corpus

The primary end-to-end corpus consists of two external EPUBs. The files are
deliberately not committed and their titles and paths are not part of trace
metadata.

| ID | Measured size | Environment variable |
| --- | ---: | --- |
| `large-epub-160m` | 168,827,004 bytes (161 MiB) | `YUEDU_PERF_EPUB_160_PATH` |
| `large-epub-224m` | 234,801,987 bytes (224 MiB) | `YUEDU_PERF_EPUB_224_PATH` |

Configure both variables with absolute paths before running
`CoreTextLargeEPUBBenchmarkTests`. The corpus contract rejects files outside
their registered size band. It also rejects macOS `dataless` placeholders:
download each file completely and confirm it has non-zero allocated bytes
before benchmarking. Cloud materialization time is I/O outside the reader and
must never be reported as EPUB-open or CoreText time.

The serialized benchmark selects the middle spine item from each publication
and records:

- publication open;
- attributed chapter build;
- first-page pagination;
- full pagination;
- warm layout-cache lookup.

It prints one `CORETEXT_BENCHMARK` line per book. The line contains only the
content-free corpus ID, counts, and durations.

Run it separately from the fast contract suites:

```bash
YUEDU_PERF_EPUB_160_PATH='/absolute/path/to/large-160.epub' \
YUEDU_PERF_EPUB_224_PATH='/absolute/path/to/large-224.epub' \
YUEDU_REQUIRE_LARGE_EPUB_CORPUS=1 \
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/CoreTextLargeEPUBBenchmarkTests' \
  -parallel-testing-enabled NO
```

### Initial simulator diagnostic

The first successful Debug simulator run on 2026-07-28 produced:

| ID | Chapters | Spine | Chars | Open | Build | First page | Full layout | Warm layout |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `large-epub-160m` | 1,881 | 940 | 3,165 | 704.48 ms | 11,025.37 ms | 18.41 ms | 10.46 ms | 0.21 ms |
| `large-epub-224m` | 1,594 | 797 | 3,546 | 1,085.68 ms | 5,128.63 ms | 5.74 ms | 12.38 ms | 1.08 ms |

The fresh verification run showed the expected Debug/simulator variance:

| ID | Open | Build | First page | Full layout | Warm layout |
| --- | ---: | ---: | ---: | ---: | ---: |
| `large-epub-160m` | 737.00 ms | 12,764.09 ms | 12.76 ms | 13.50 ms | 0.22 ms |
| `large-epub-224m` | 1,008.34 ms | 7,111.32 ms | 7.44 ms | 13.51 ms | 1.10 ms |

This is a diagnostic, not a release performance gate. It already establishes
that attributed chapter building consumed about 82–94% of the measured
end-to-end time, while first-page and full pagination each stayed below 20 ms.
The smaller archive was slower despite a similar representative chapter length,
so archive size and character count alone do not explain the bottleneck. Use
the nested `html.*`, `css.*`, `ast.*`, `ir.*`, and `resource.*` signposts in a
Release Instruments capture to split that build cost before optimizing.

### First measured optimization: reject absent manifest resources

The first Time Profiler capture showed that the chapter-build critical path was
dominated by repeated resource lookup and error logging around `@font-face`,
not by Core Text pagination. The two corpus books each contain roughly 123
`@font-face` declarations but package only 4 and 11 font files. Before the
change, every missing font entered Readium resource lookup; linked and imported
stylesheets caused the same absent resources to be probed repeatedly.

`BookResourceProvider.resourceAvailability(for:)` now exposes an optional
authoritative availability check. The Readium adapter answers it from the OPF
manifest's normalized href set in O(1). Unknown providers return `nil` and keep
the existing load path. `EPUBStyleResolver` only skips a font when the provider
explicitly returns `false`.

`PublicationSession.response(for:)` also avoids reopening and extracting the
archive unless the requested resource actually declares an encryption or font
obfuscation algorithm. Obfuscated resources retain the existing raw-byte
deobfuscation path.

Two Debug simulator iterations after both changes produced:

| ID | Iteration | Open | Build | First page | Full layout | Warm layout |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `large-epub-160m` | 1 | 662.91 ms | 983.92 ms | 7.37 ms | 7.67 ms | 0.28 ms |
| `large-epub-160m` | 2 | 1,237.93 ms | 1,638.43 ms | 4.74 ms | 14.62 ms | 0.38 ms |
| `large-epub-224m` | 1 | 1,712.13 ms | 3,236.51 ms | 16.67 ms | 35.74 ms | 1.92 ms |
| `large-epub-224m` | 2 | 1,071.45 ms | 2,272.16 ms | 12.01 ms | 18.38 ms | 2.03 ms |

Against the two fresh pre-change captures, attributed chapter build improved
by approximately 85–92% for `large-epub-160m` and 39–68% for
`large-epub-224m`. Character counts, selected spines, and seven-page layout
results remained unchanged. These are still simulator diagnostics; the Release
physical-device median/p95 gate remains outstanding.

### Content revision: remove duplicate layout fingerprint scans

The page engine uses one attributed chapter build for its first-page and full
pagination passes. Previously both calls independently performed the same O(N)
text-and-attribute fingerprint before entering background layout.

`AttributedChapterBuildResult` now owns an opaque `ContentRevision`. The page
and TXT engines pass that value through `PaginationRequest`, and first-page,
full, and warm pagination use it as their shared in-memory cache identity.
Legacy direct paginator callers can omit the revision and retain the complete
fingerprint path.

The focused contract proves:

- production first-page + full pagination: fingerprint computations `2 → 0`;
- legacy first-page + full pagination: fingerprint computations remain `2`;
- changing an explicit revision or legacy fingerprint prevents stale cache
  hits;
- a warm request with the same revision returns the same framesetter object.

A mutation check temporarily removed content identity from the cache key. The
two stale-content tests failed as intended, then passed after the correct key
was restored.

The post-change large-corpus verification retained the same selected spines,
character counts, and seven-page ranges:

| ID | Open | Build | First page | Full layout | Warm layout |
| --- | ---: | ---: | ---: | ---: | ---: |
| `large-epub-160m` | 748.90 ms | 2,304.28 ms | 124.16 ms | 33.21 ms | 0.08 ms |
| `large-epub-224m` | 1,679.16 ms | 3,221.14 ms | 28.18 ms | 38.36 ms | 0.05 ms |

These representative chapters contain only 3–4K rendered characters, so their
single-run first-page timing is dominated by Debug simulator variance. The
deterministic improvement claim is the elimination of two full-content scans;
absolute latency must be measured with the 100K synthetic fixture and Release
physical-device capture before setting a gate.

## PageLayoutArtifact: Single Ownership of Final Page Frames

`CoreTextPaginator` now creates `PageLayoutArtifact` values after final page
ranges and float notches are known. Each artifact retains one `CTFrame` and its
line origins for attachment, inline annotation, block decoration, page drawing,
and interaction hit testing.

Automated acceptance:

- artifact count equals final page-range count;
- every artifact range equals its final page range;
- page rendering returns the exact `CTFrame` object retained by the artifact;
- a mutation forcing draw-time frame recreation changes the focused result
  from 2/2 passing to 1/2 passing.

This does not claim that the whole pagination algorithm creates only one frame
per page. Page-range probes and orphan/widow correction still need temporary
frames before final ranges exist. The deterministic result is removal of
repeated shaping of the same **final page** during metadata extraction and draw.

## Capture Procedure

Use a Release build on a physical device with a fixed iOS version:

1. Open Instruments and choose Points of Interest together with Time Profiler.
2. Filter signposts by category `ReaderPerformance`.
3. Record paged and scrolling modes separately.
4. Record cold and warm opens separately; do not mix them in one result.
5. Run each scenario at least 10 times and report median and p95.
6. For scrolling, use the same 10-second gesture and also record Core Animation
   hitches and peak resident memory.

The existing `SourcePerfTrace` `coreText.firstPage` and `coreText.fullLayout`
Console lines remain useful for field diagnostics. Instruments signposts are
the source of truth for nested stage attribution.

## Focused Contract Tests

Run the two fast suites before capturing a baseline:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/ReaderPerfTraceTests' \
  -only-testing:'yuedu appTests/CoreTextPerformanceFixtureTests' \
  -parallel-testing-enabled NO
```

When the change touches vertical preparation or layout, also run:

```bash
xcodebuild test \
  -project Yuedu-Reader.xcodeproj \
  -scheme Yuedu-Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:'yuedu appTests/CoreTextWritingModeTests' \
  -parallel-testing-enabled NO
```

## Result Template

Record device and build identity with every result:

| Field | Value |
| --- | --- |
| Commit | |
| Configuration | Release |
| Device | |
| iOS | |
| Fixture | |
| Mode | paged / scroll |
| Writing | horizontal / vertical-rl |
| Cache state | cold / warm |

| Metric | Median | p95 | Notes |
| --- | ---: | ---: | --- |
| `chapter.load` | | | |
| `layout.fingerprint` | | | |
| `layout.pageRanges` | | | |
| `layout.displayList` | | | |
| `layout.firstPage.publish` | | | |
| `render.page` / `render.chunk` | | | |
| Peak RSS | | | |
| Scroll hitch ratio | | | |

Do not merge an optimization on subjective smoothness alone. Attach the before
and after table, confirm reading-position/page-range parity, and state any cache
or memory tradeoff.
