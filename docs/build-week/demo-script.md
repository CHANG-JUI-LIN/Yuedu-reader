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

## Capture checklist

- Record app scenes in portrait on the same iPhone simulator where practical.
- Use the committed evidence PNGs directly; do not reconstruct or retouch book content.
- Keep official-sample license attribution in the repository evidence package.
- Show `29 / 43` and `43 / 43` long enough to read.
- Verify the public YouTube setting after upload.
- Listen once with the screen hidden; the narration must still explain the product, Codex, GPT-5.6, and the measured result.
