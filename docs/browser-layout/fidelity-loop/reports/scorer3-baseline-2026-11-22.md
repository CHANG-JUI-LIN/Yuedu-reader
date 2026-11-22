# Render fidelity — scorer3-baseline-2026-11-22

> **評分方式改版（scorer 2 → 3，2026-11-22，維護者要求）。** 量測工具原本把一本書的每一份文件都用「書的書寫方向」擷取。閱讀器是每份文件用自己的方向（`BookWritingModes`；沒有文字的頁面才跟書）。直排書裡的橫排版權頁因此在這裡被排成直排、被新引擎拒絕，報告成閱讀器實際不會發生的舊引擎回退。現在每一章用捲動模式實際採用的方向擷取；對照組若是在另一個方向的視窗下擷取的，會重新擷取。
>
> 同一個引擎（套件 0.29.1 對 0.29.0）新舊評分的差異只有 book-770f5d9a 的第 11、12 章（16.7 → 97.2、12.8 → 98.5），這本書 85.6 → 97.5；其餘 565 章沒有一章變動超過 1 分。567 章全部走新引擎。
>
> 這份是 scorer 3 的基線（run `s3-baseline-0291`）；對照的 scorer 2 是 run `s2-after`。

Generated 2026-11-23T00:20:13 · scorer v3 · reference `ios27.2-32c823fa58959671`

Measured: reader `~/Desktop/Yuedu-reader (main 39ca7b9d + uncommitted changes)` · engine package `https://github.com/CHANG-JUI-LIN/YueduCoreText @ 0.29.1`

**Goal (every book ≥ 80): not met** — 35 of 36 books pass.

| Book | Score | Dev | Holdout | Layout | Visual | Lowest chapter | Chapters | Browser / Legacy | Below 60 (spine) | Unmeasured |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|
| mahabharata ✗ | **78.8** | 80.6 | 75.8 | 78.5 | 88.4 | 73.8 | 16 | 16 / 0 | — | 0 |
| book-4c6b296c | **81.0** | 80.7 | 81.5 | 78.0 | 94.4 | 77.6 | 16 | 16 / 0 | — | 0 |
| redchamber-vertical | **82.7** | 82.4 | 83.1 | 81.8 | 84.2 | 71.8 | 16 | 16 / 0 | — | 0 |
| book-8fbb4b7b | **89.2** | 89.5 | 88.8 | 87.9 | 96.5 | 80.8 | 16 | 16 / 0 | — | 0 |
| book-782cc072 | **91.2** | 91.4 | 91.0 | 90.7 | 97.6 | 86.9 | 16 | 16 / 0 | — | 0 |
| book-f2209900 | **91.8** | 91.9 | 91.5 | 91.3 | 95.9 | 87.8 | 16 | 16 / 0 | — | 0 |
| book-40e2c051 | **91.8** | 91.7 | 92.1 | 92.2 | 93.5 | 85.4 | 16 | 16 / 0 | — | 0 |
| book-376d3716 | **92.3** | 92.8 | 91.4 | 91.6 | 98.1 | 86.6 | 16 | 16 / 0 | — | 0 |
| hail-mary | **92.4** | 91.7 | 93.6 | 91.5 | 97.2 | 86.3 | 17 | 17 / 0 | — | 0 |
| book-d53a7692 | **92.8** | 93.8 | 91.2 | 98.0 | 87.7 | 87.4 | 16 | 16 / 0 | — | 0 |
| israelsailing | **92.9** | 91.8 | 98.1 | 95.5 | 90.3 | 38.2 | 12 | 12 / 0 | 1 | 0 |
| book-6fd6695e | **94.4** | 94.7 | 93.8 | 98.0 | 88.0 | 64.4 | 16 | 16 / 0 | — | 0 |
| book-ce879db4 | **94.6** | 93.5 | 96.5 | 98.1 | 80.7 | 58.9 | 16 | 16 / 0 | 0 | 0 |
| guimi | **95.0** | 94.0 | 97.6 | 98.0 | 91.9 | 86.0 | 21 | 21 / 0 | — | 0 |
| hongwu | **95.4** | 94.2 | 97.2 | 99.4 | 90.9 | 67.2 | 16 | 16 / 0 | — | 0 |
| redchamber | **95.8** | 95.0 | 97.6 | 97.8 | 93.9 | 84.7 | 18 | 18 / 0 | — | 0 |
| book-8b70d206 | **95.8** | 94.6 | 97.8 | 98.8 | 80.4 | 64.1 | 16 | 16 / 0 | — | 0 |
| book-c0e3d541 | **96.2** | 96.6 | 95.4 | 99.9 | 90.4 | 94.7 | 16 | 16 / 0 | — | 0 |
| harry-potter | **96.3** | 95.4 | 97.9 | 99.5 | 92.6 | 80.2 | 16 | 16 / 0 | — | 0 |
| book-3804b2ae | **96.6** | 96.5 | 96.7 | 99.6 | 93.2 | 91.4 | 16 | 16 / 0 | — | 0 |
| quanzhi | **97.2** | 96.5 | 98.6 | 99.1 | 95.3 | 85.2 | 18 | 18 / 0 | — | 0 |
| orv | **97.2** | 97.0 | 97.7 | 99.7 | 94.7 | 90.6 | 16 | 16 / 0 | — | 0 |
| book-770f5d9a | **97.5** | 97.9 | 96.3 | 98.0 | 96.4 | 94.5 | 14 | 14 / 0 | — | 0 |
| book-16ebf943 | **97.5** | 98.6 | 95.8 | 98.3 | 96.9 | 84.8 | 16 | 16 / 0 | — | 0 |
| kusamakura | **97.5** | 97.0 | 98.6 | 98.9 | 70.6 | 90.0 | 15 | 15 / 0 | — | 0 |
| georgia | **97.7** | 97.7 | — | 97.3 | 99.0 | 97.7 | 1 | 1 / 0 | — | 0 |
| book-47e03e8c | **97.7** | 97.9 | 97.4 | 98.8 | 95.8 | 96.8 | 16 | 16 / 0 | — | 0 |
| ai-glossary | **97.8** | 97.8 | 97.8 | 99.3 | 96.2 | 95.4 | 16 | 16 / 0 | — | 0 |
| game-designer | **97.9** | 97.5 | 98.8 | 99.6 | 96.1 | 80.1 | 19 | 19 / 0 | — | 0 |
| book-d3cb8cb5 | **98.0** | 97.1 | 99.6 | 99.0 | 94.7 | 72.3 | 16 | 16 / 0 | — | 0 |
| book-199bcc55 | **98.1** | 98.3 | 97.7 | 98.0 | 98.1 | 94.6 | 16 | 16 / 0 | — | 0 |
| sherlock | **98.2** | 98.5 | 97.6 | 99.2 | 96.9 | 94.6 | 16 | 16 / 0 | — | 0 |
| book-f0f1d275 | **98.4** | 97.6 | 99.8 | 99.0 | 97.2 | 77.1 | 16 | 16 / 0 | — | 0 |
| book-0be89331 | **99.2** | 99.1 | 99.2 | 100.0 | 98.3 | 98.5 | 16 | 16 / 0 | — | 0 |
| book-772d4bf7 | **99.3** | 99.3 | 99.2 | 100.0 | 98.2 | 98.9 | 16 | 16 / 0 | — | 0 |
| the-deal | **99.6** | 99.6 | 99.7 | 99.8 | 99.1 | 98.2 | 16 | 16 / 0 | — | 0 |

## Where the points go

Points are book-score points: what one book loses on average to each cause.

| Cause | Points |
|---|---:|
| line-break | 1.71 |
| paint:image | 0.93 |
| paint:other | 0.77 |
| font-size | 0.30 |
| paint:background | 0.27 |
| line-count | 0.27 |
| inline-start | 0.23 |
| indent | 0.20 |
| block-gap | 0.18 |
| inline-size | 0.18 |
| paint:border | 0.18 |
| image-size | 0.08 |

## Largest gaps by CSS context

| Cause | Context of the reference block | Points |
|---|---|---:|
| line-break | plain | 1.67 |
| font-size | plain | 0.27 |
| line-count | plain | 0.26 |
| inline-start | plain | 0.21 |
| indent | plain | 0.19 |
| inline-size | plain | 0.17 |
| block-gap | plain | 0.09 |
| image-size | plain | 0.08 |

## Engine route of the measured chapters

Browser engine: 567 chapters, mean 94.5. Legacy fallback: 0 chapters, mean —.

A chapter falls back whole when the capability scanner finds any of these; one chapter can name several.

| Fallback reason | Chapters | Books | Mean score of those chapters |
|---|---:|---|---:|

| Route as reported | Chapters |
|---|---:|
| browser | 567 |

## Reference caveats

| Book | Chapters | Caveat |
|---|---:|---|
| book-772d4bf7 | 15 | fonts still loading when the reference was measured |
| harry-potter | 8 | fonts still loading when the reference was measured |
