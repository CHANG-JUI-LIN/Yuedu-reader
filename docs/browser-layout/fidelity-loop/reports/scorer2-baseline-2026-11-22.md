# Render fidelity — scorer2-baseline-2026-11-22

> **評分方式改版（scorer 1 → 2，2026-11-22，維護者要求）。** 量測工具替閱讀器那一側算直排文字框時，把欄的中線當成一般基線：框從 `baseline − descent` 起算，比字本身偏了約 7 點。兩邊整頁背景一致時（草枕的 `html` 米色底在 0.29.0 對上之後），偏出框外的筆畫被當成「多畫的東西」計入視覺分。現在框以中線為中心，寬度是進位後的 ascent + descent，和 WebKit 回報的框相同。橫排的算法沒有變。
>
> 同一個引擎（套件 0.28.0）新舊評分的差異只出現在三本直排書，其餘 33 本每一本的分數都相同：
>
> | 書 | scorer 1 | scorer 2 |
> |---|---:|---:|
> | book-770f5d9a | 72.4 | 85.6 |
> | kusamakura | 79.7 | 80.5 |
> | redchamber-vertical | 78.9 | 82.6 |
>
> 直排章節的分數從這份報告起不能和 scorer 1 的報告直接比較。這份是 scorer 2 的基線（run `s2-baseline-0280`）；對照的 scorer 1 是 run `root-corpus-after`。

Generated 2026-11-22T21:56:23 · scorer v2 · reference `ios27.2-32c823fa58959671`

Measured: reader `~/Desktop/Yuedu-reader (main 4b893ea3 + uncommitted changes)` · engine package `https://github.com/CHANG-JUI-LIN/YueduCoreText @ 0.28.0`

**Goal (every book ≥ 80): not met** — 35 of 36 books pass.

| Book | Score | Dev | Holdout | Layout | Visual | Lowest chapter | Chapters | Browser / Legacy | Below 60 (spine) | Unmeasured |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|
| mahabharata ✗ | **78.8** | 80.6 | 75.8 | 78.5 | 88.4 | 73.8 | 16 | 16 / 0 | — | 0 |
| kusamakura | **80.5** | 79.3 | 82.9 | 90.0 | 71.0 | 41.8 | 15 | 14 / 1 | 0 | 0 |
| book-4c6b296c | **81.0** | 80.7 | 81.5 | 78.0 | 94.4 | 77.6 | 16 | 16 / 0 | — | 0 |
| redchamber-vertical | **82.6** | 82.4 | 83.0 | 81.8 | 84.1 | 71.8 | 16 | 16 / 0 | — | 0 |
| book-770f5d9a | **85.6** | 89.3 | 76.3 | 85.6 | 85.6 | 12.8 | 14 | 12 / 2 | 11, 12 | 0 |
| book-8fbb4b7b | **89.2** | 89.5 | 88.8 | 87.9 | 96.4 | 80.8 | 16 | 16 / 0 | — | 0 |
| book-782cc072 | **91.2** | 91.4 | 91.0 | 90.7 | 97.6 | 86.9 | 16 | 16 / 0 | — | 0 |
| book-f2209900 | **91.8** | 92.0 | 91.5 | 91.3 | 96.0 | 87.8 | 16 | 16 / 0 | — | 0 |
| book-40e2c051 | **92.0** | 91.5 | 92.8 | 92.2 | 94.4 | 84.3 | 16 | 16 / 0 | — | 0 |
| hail-mary | **92.3** | 91.6 | 93.6 | 91.5 | 97.2 | 86.0 | 17 | 17 / 0 | — | 0 |
| book-376d3716 | **92.3** | 92.9 | 91.4 | 91.6 | 98.2 | 86.6 | 16 | 16 / 0 | — | 0 |
| israelsailing | **92.8** | 91.8 | 98.0 | 95.5 | 90.3 | 38.2 | 12 | 12 / 0 | 1 | 0 |
| book-d53a7692 | **92.8** | 93.8 | 91.2 | 98.0 | 87.7 | 87.4 | 16 | 16 / 0 | — | 0 |
| book-6fd6695e | **94.4** | 94.7 | 93.8 | 98.0 | 88.0 | 64.4 | 16 | 16 / 0 | — | 0 |
| book-ce879db4 | **94.6** | 93.4 | 96.5 | 98.1 | 80.5 | 58.9 | 16 | 16 / 0 | 0 | 0 |
| guimi | **95.0** | 94.0 | 97.6 | 98.0 | 91.9 | 86.0 | 21 | 21 / 0 | — | 0 |
| hongwu | **95.2** | 94.0 | 97.2 | 99.4 | 90.6 | 67.3 | 16 | 16 / 0 | — | 0 |
| book-8b70d206 | **95.9** | 94.7 | 97.8 | 98.8 | 80.4 | 64.1 | 16 | 16 / 0 | — | 0 |
| redchamber | **95.9** | 95.0 | 97.6 | 97.8 | 93.9 | 84.9 | 18 | 18 / 0 | — | 0 |
| book-c0e3d541 | **96.1** | 96.5 | 95.5 | 99.9 | 90.3 | 94.7 | 16 | 16 / 0 | — | 0 |
| harry-potter | **96.3** | 95.4 | 97.9 | 99.5 | 92.6 | 80.0 | 16 | 16 / 0 | — | 0 |
| book-3804b2ae | **96.6** | 96.5 | 96.7 | 99.6 | 93.2 | 91.4 | 16 | 16 / 0 | — | 0 |
| quanzhi | **97.1** | 96.3 | 98.5 | 99.1 | 95.0 | 85.3 | 18 | 18 / 0 | — | 0 |
| orv | **97.1** | 97.2 | 96.8 | 99.7 | 94.5 | 92.2 | 16 | 16 / 0 | — | 0 |
| book-16ebf943 | **97.5** | 98.6 | 95.8 | 98.3 | 96.9 | 84.8 | 16 | 16 / 0 | — | 0 |
| georgia | **97.7** | 97.7 | — | 97.3 | 99.0 | 97.7 | 1 | 1 / 0 | — | 0 |
| book-47e03e8c | **97.7** | 97.8 | 97.5 | 98.8 | 95.8 | 96.9 | 16 | 16 / 0 | — | 0 |
| ai-glossary | **97.8** | 97.7 | 97.9 | 99.3 | 96.3 | 95.5 | 16 | 16 / 0 | — | 0 |
| game-designer | **97.9** | 97.5 | 98.7 | 99.6 | 96.2 | 80.3 | 19 | 19 / 0 | — | 0 |
| book-d3cb8cb5 | **98.0** | 97.1 | 99.6 | 99.0 | 94.6 | 72.3 | 16 | 16 / 0 | — | 0 |
| book-199bcc55 | **98.1** | 98.3 | 97.7 | 98.0 | 98.1 | 94.6 | 16 | 16 / 0 | — | 0 |
| sherlock | **98.2** | 98.5 | 97.6 | 99.2 | 96.9 | 94.6 | 16 | 16 / 0 | — | 0 |
| book-f0f1d275 | **98.5** | 97.6 | 99.9 | 99.1 | 97.2 | 77.1 | 16 | 16 / 0 | — | 0 |
| book-0be89331 | **99.1** | 99.1 | 99.2 | 100.0 | 98.2 | 98.5 | 16 | 16 / 0 | — | 0 |
| book-772d4bf7 | **99.3** | 99.3 | 99.2 | 100.0 | 98.2 | 98.9 | 16 | 16 / 0 | — | 0 |
| the-deal | **99.6** | 99.6 | 99.7 | 99.8 | 99.2 | 98.2 | 16 | 16 / 0 | — | 0 |

## Where the points go

Points are book-score points: what one book loses on average to each cause.

| Cause | Points |
|---|---:|
| line-break | 1.76 |
| paint:other | 1.18 |
| paint:image | 0.93 |
| font-size | 0.33 |
| line-count | 0.28 |
| paint:background | 0.28 |
| inline-start | 0.24 |
| block-gap | 0.23 |
| paint:border | 0.21 |
| indent | 0.20 |
| inline-size | 0.19 |
| image-size | 0.08 |
| paint:writing-mode | 0.07 |
| writing-mode | 0.06 |
| line-pitch | 0.06 |

## Largest gaps by CSS context

| Cause | Context of the reference block | Points |
|---|---|---:|
| line-break | plain | 1.72 |
| font-size | plain | 0.30 |
| line-count | plain | 0.27 |
| inline-start | plain | 0.23 |
| indent | plain | 0.19 |
| inline-size | plain | 0.18 |
| block-gap | plain | 0.14 |
| image-size | plain | 0.08 |
| writing-mode | plain | 0.06 |

## Engine route of the measured chapters

Browser engine: 564 chapters, mean 94.2. Legacy fallback: 3 chapters, mean 23.7.

A chapter falls back whole when the capability scanner finds any of these; one chapter can name several.

| Fallback reason | Chapters | Books | Mean score of those chapters |
|---|---:|---|---:|
| vertical-writing-mode | 3 | book-770f5d9a, kusamakura | 23.7 |

| Route as reported | Chapters |
|---|---:|
| browser | 564 |
| legacy: capability vertical-writing-mode | 3 |

## Reference caveats

| Book | Chapters | Caveat |
|---|---:|---|
| book-772d4bf7 | 15 | fonts still loading when the reference was measured |
| harry-potter | 8 | fonts still loading when the reference was measured |
