# Official EPUB 3 gap ranking

This ranking records the initial official-corpus capture and eight-book manual
pass that selected bounded follow-up work. It is historical triage, not a
current support claim. At selection time, 14 of 42 samples failed the
production smoke checkpoint and manual review added one shared navigation
failure family in four otherwise-readable representative books.

Final Build Week status: all 14 initial automated failures now pass. The final
acceptance follow-up preserves `cc-shared-culture`'s authored static media
fallback without expanding scope into a full interactive audio/video system.
The compatibility matrix and seven linked evidence packages are the current
source of truth.

Scores are intentionally small and comparative:

- **Severity (0–3):** 3 blocks opening, reading, or navigation; 2 loses a
  meaningful presentation/fallback; 1 loses a limited enhancement; 0 is not a
  verified product defect.
- **Reach (0–3):** 3 affects common long-form reading; 2 affects a meaningful
  EPUB feature family or several official samples; 1 is narrow; 0 is
  harness-only.
- **Demo (0–2):** 2 has a clear before/after checkpoint; 1 is primarily
  diagnostic; 0 cannot support a useful Build Week comparison.
- **Fixture (0–2):** 2 is deterministic with a small synthetic EPUB; 1 needs a
  hosted WebKit/UI checkpoint; 0 still depends on the external corpus.

The total is the sum out of 10. Selection first takes the highest totals, then
deduplicates failure families. MathML and English typography remain their
already-approved workstreams. Pre-existing support and full interactive media
systems are not eligible as newly-added Build Week features.

## Ranked failing or partial samples

| Sample | Observed failure family | Sev. | Reach | Demo | Fixture | Total | Disposition |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `accessible-epub3` | Long-TOC selection starts synchronous navigation before sheet dismissal | 3 | 3 | 2 | 2 | **10** | Select shared family as `BW-EPUB3-001` |
| `childrens-literature` | Same TOC sheet stall after leaving the image-centric cover | 3 | 3 | 2 | 2 | **10** | Covered by `BW-EPUB3-001` |
| `linear-algebra` | Same TOC sheet stall prevents reaching the requested dense-equation checkpoint | 3 | 3 | 2 | 2 | **10** | Covered by `BW-EPUB3-001`; formula quality stays in the MathML workstream |
| `moby-dick` | Same TOC sheet stall after leaving the image-centric cover | 3 | 3 | 2 | 2 | **10** | Covered by `BW-EPUB3-001`; typography stays in the English workstream |
| `kusamakura` | Percent-encoded non-ASCII spine href cannot be read | 3 | 2 | 2 | 2 | **9** | Select shared family as `BW-EPUB3-002` |
| `kusamakura-preview` | Percent-encoded non-ASCII spine href cannot be read | 3 | 2 | 2 | 2 | **9** | Covered by `BW-EPUB3-002` |
| `kusamakura-preview-embedded` | Percent-encoded non-ASCII spine href cannot be read | 3 | 2 | 2 | 2 | **9** | Covered by `BW-EPUB3-002` |
| `the-voyage-of-life` | Item-level pre-paginated spine entry is routed through the reflowable engine | 3 | 2 | 2 | 2 | **9** | Select as `BW-EPUB3-003` |
| `cc-shared-culture` | Static media fallback probe is absent, although the transcript body survives | 2 | 2 | 2 | 2 | **8** | Resolved as `BW-EPUB3-007`; interactive audio/video remains out of scope |
| `haruko` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Hold pending route-specific fixed-reader diagnosis |
| `haruko-ahl` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Same fixed-layout family |
| `haruko-jpeg` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Same fixed-layout family |
| `page-blanche` | Hosted smoke sees no pixels, but formal `fixedPage` metadata renders cover/Page 3 and preserves Page 3 through rotation | 0 | 0 | 1 | 2 | **3** | Treat as harness observability until the remaining spread/pages checklist proves a product defect |
| `page-blanche-jpeg` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Same fixed-layout family |
| `sous-le-vent` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Same fixed-layout family |
| `sous-le-vent-svg` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Same fixed-layout family |
| `svg-in-spine` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Same fixed-layout family |
| `the-voyage-of-life-tol` | Hosted fixed-layout smoke sees no observable WebKit pixels within three seconds | 2 | 2 | 2 | 1 | **7** | Same fixed-layout family; scripting remains out of scope |

`israelsailing` and `wasteland-otf` passed their first manual checkpoints and
are therefore not ranked as gaps. Their behavior is baseline-supported, not a
Build Week addition. The first `page-blanche` direct seed used the wrong
general `epub` route and is excluded. The corrected seed reproduced both
formal-import fields—`fixedPage` and all 10 spine refs—and rendered the cover
and Page 3 while preserving Page 3 through rotation. Its remaining hosted
failure is not treated as a product defect without route-specific evidence.

## Selected failure families

### BW-EPUB3-001 — Dismiss TOC before navigation work

Inspection found both horizontal and vertical selection handlers in
`Modules/Features/Reader/ReaderTOCViews.swift` call `onSelectChapter` before
setting `isPresented = false`. The callback reaches
`ReaderView.jumpToChapter`, which synchronously asks the engine for a page view
controller before the sheet can commit its dismissal. The focused plan makes
dismissal ordering deterministic and covers it with a long synthetic TOC:

- [TOC dismissal implementation plan](../../superpowers/plans/2026-07-15-epub3-toc-dismissal.md)

### BW-EPUB3-002 — Resolve encoded and decoded resource IRIs

The three Kusamakura variants fail at `PublicationSession.chapterHTML` with an
encoded href such as `OPS/xhtml/%E4%B8%80.xhtml`. The OPF/archive resource uses
the Unicode filename `OPS/xhtml/一.xhtml`, while
`PublicationSession.readiumURLs(for:)` currently tries only raw, leading-slash,
and no-leading-slash forms. The focused plan adds canonical encoded/decoded
candidates once at this resource boundary:

- [Non-ASCII IRI implementation plan](../../superpowers/plans/2026-07-15-epub3-non-ascii-iri.md)

### BW-EPUB3-003 — Route mixed-layout spine items by effective layout

`PublicationSession` already parses each descriptor's `layoutModeOverride`,
but `EPUBPageRenderer.load` chooses a single engine using only the publication-
level `session.layoutMode`. Consequently the fixed painting in the globally
reflowable `the-voyage-of-life` sample is sent to CoreText. The focused plan
adds a composite page map rather than weakening the smoke assertion:

- [Mixed-layout routing implementation plan](../../superpowers/plans/2026-07-15-epub3-mixed-layout-routing.md)

The three selected gap plans do not change MathML, English typography, Media
Overlay, audio/video, RTL/Bidi, Ruby, CFI, or PLS/SSML support claims. MathML
and English were implemented and evidenced in their separate approved
workstreams. `BW-EPUB3-007` is a bounded acceptance follow-up: it retains
authored fallback children only when no native media player is surfaced, and
does not add or claim a new interactive media system.
