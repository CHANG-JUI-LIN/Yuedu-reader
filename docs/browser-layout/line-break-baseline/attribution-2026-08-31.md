# BrowserLayout Line-Break Baseline Difference Attribution

Date: 2026-08-31

This is a diagnostic report. Production layout was restored after every
temporary toggle, and `redchamber.tsv` was not modified.

## Controlled states

- `ROOT_BEFORE`: current source tree with only horizontal root content origin
  temporarily set to zero.
- `ROOT_AFTER`: current source tree with the generic root content-origin fix.
- `ROOT_AFTER_REPEAT`: an independent repeat using the same simulator, font
  environment, reader settings, corpus, and shared DerivedData.
- `PROVISIONAL_INLINE_SIZE`: current source tree with root X set to zero and
  only the Phase 4E0 `establishedInlineSize` compatibility contract restored.
- `HINTS_OFF`: current source tree with root X set to zero and only HTML
  presentational hints disabled before cascade.
- `ffeaf95-zero-indent`: commit `ffeaf95` with the typed computed-style tree
  cloned to `textIndent = .initial`; this avoids contaminating the comparison
  with Phase 4E1.

All whole-book states covered 458 of 458 spines with zero scanner skips.

## Root-X before/after result

| Metric | Before | After | Result |
|---|---:|---:|---|
| Aggregate pages | 3,820 | 3,820 | identical |
| Logical box lines | 116,714 | 116,714 | identical |
| Text fragments | 137,294 | 137,294 | identical |
| Source UTF-16 length | 2,231,613 | 2,231,613 | identical |
| Chapters with changed box digest | 0 | 0 | identical |
| Chapters with changed page-range digest | 0 | 0 | identical |
| Chapters with changed fragment digest | 296 | 296 | X-only |

The strict row comparison found 63,912 changed fragment rows:

- 59,723 text fragments;
- 3,930 image fragments;
- 259 fill fragments.

Every changed row differed only in `rect.x` and `documentRect.x`. Fragment Y,
width, height, baseline, source range, node identity, font data, page source
range, and logical line geometry were identical. The affected chapters had one
uniform root-origin delta each: `+3.66pt` for 295 chapters and `+8pt` for the
cover chapter that retains the UA body margin.

`ROOT_AFTER` and `ROOT_AFTER_REPEAT` were byte-identical NDJSON captures with
SHA-256
`897103f5fec99731e263e2f847940c492e05bc0036d2cd189ef209b3c2528815`.
There was no font/process variance in the current tree.

## Commit-boundary result

The valid `ffeaf95-zero-indent` replay was byte-for-byte identical to the
existing golden for all 458 spines. Both files had SHA-256
`0abeaccf092331e6997e4376d071b92bc1f1295aa98b7f53b79747728863fdce`.

This excludes Phase 4E0, horizontal Ruby, float, and the zeroed Phase 4E1
text-indent path as sources of the current pre-root-X line/page differences.

## Used-value isolation

The EPUB authors `body` and `p` percentage horizontal margins. The golden-era
pipeline shaped nested paragraph content against a provisional `366pt`
interval. The current used-value contract resolves:

`body: 358.68pt -> p: 351.5064pt`

Toggling only the IFC width contract changed:

| Metric | Provisional width | Final content width |
|---|---:|---:|
| Aggregate pages | 3,683 | 3,820 |
| Logical box lines | 111,404 | 116,714 |
| Text fragments | 131,908 | 137,294 |
| Source UTF-16 length | 2,231,613 | 2,231,613 |

It affected 401 baseline rows, 274 chapters' logical-line counts, 275 chapters'
text-fragment counts, 128 chapters' page counts, and 250 chapters' page-range
digests. Restoring the provisional contract returned 243 of the 401
pre-existing failures exactly to the old golden.

The remaining no-hint differences are line-height finalization: their visible
signatures are exclusively line Y, height, and baseline changes (plus the
downstream page boundary/digest where accumulated height crosses a page).

## Presentational-hint isolation

Seventy-eight spines contain relevant image width/height attributes. The
production hint on/off differential proves that hints materially affect 43 of
them. Across those 43 chapters, hints changed five page counts, five logical
line counts, five text-fragment counts, and 43 page-range/geometry digests.
The other 35 attribute-bearing chapters are overridden by author CSS or are
geometry-neutral for this baseline.

## Current golden failure classification

| Classification | Chapters |
|---|---:|
| `EXPECTED_X_ONLY` | 32 |
| `PREEXISTING_LINE_BREAK_DIFF` | 279 |
| `PREEXISTING_PAGE_DIFF` | 122 |
| `FONT_PROCESS_VARIANCE` | 0 |
| `NEW_REGRESSION` | 0 |
| `UNKNOWN` | 0 |

Provenance for the 433 failures:

| Earliest generic source | Chapters |
|---|---:|
| Root fragment content-origin X | 32 |
| Used-value final IFC width | 243 |
| Used-value final IFC width plus line-height finalization | 115 |
| Phase 4F0 presentational hints, with later final-width effects | 43 |

The complete per-spine classification is in
`attribution-2026-08-31.tsv`. Its `lines` columns preserve the existing
golden's terminology but count text fragments; logical-line counts were
measured separately in the detailed captures above.

## Golden update policy

- The 32 `EXPECTED_X_ONLY` rows are attributable solely to the generic root-X
  fix.
- The other 401 rows predate root-X and must be updated under their own
  provenance groups, not swept into the root-X update.
- A future deliberate update may apply all four proven groups, but must retain
  the rule grouping above and must not be described as a single root-X golden
  re-record.
