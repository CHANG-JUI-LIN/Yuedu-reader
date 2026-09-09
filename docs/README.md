---
title: Yuedu 文件首頁
tags: [yuedu, index]
---

# Yuedu 文件首頁

這個 vault 就是專案原有的 `docs/`。在 Obsidian 編輯會直接修改 repo 文件，原有目錄與連結維持原位。

## 從這裡開始

- **現在做什麼：** [BrowserLayout 目前狀態與下一步](browser-layout/STATUS.md)
- **之前做過什麼：** [BrowserLayout Phase 歷史台帳](browser-layout/PHASES.md)
- **如何繼續實作：** [Phase 5A 設計](superpowers/specs/2026-09-04-lexbor-css-frontend-production-migration-design.md) · [執行計畫](superpowers/plans/2026-09-04-lexbor-css-frontend-production-migration.md)

## 文件入口

| 主題 | 入口 |
|---|---|
| 閱讀引擎 | [CoreText 索引](coretext/README.md) · [渲染管線](coretext/rendering-pipeline.md) · [互動](coretext/interaction.md) |
| EPUB 驗證 | [回歸樣本](epub-regression/README.md) · [相容性矩陣](epub-regression/compatibility-matrix.md) |
| BrowserLayout 證據 | [橫排基線結案](browser-layout/line-break-baseline/closure-2026-08-31.md) · [能力普查](browser-layout/phase4c-epub-layout-capability-census.md) · [Used-value audit](browser-layout/used-value-resolution-timing-audit.md) |
| 產品設計 | [UI 規範](design.md) · [功能展示](demo/README.md) |
| 書源 | [書源文件](book-source/README.md) |
| 技術文章 | [從 WebView 到 CoreText](blog/from-webview-to-coretext.md) · [EPUB3 適配](blog/coretext-epub3-adaptation.md) |

## 最小維護方式

1. 開工前讀 `STATUS.md`；只在這裡維護目前狀態與下一件事。
2. 設計與步驟仍放原有 `superpowers/specs/`、`superpowers/plans/`；測試數據與結案報告仍放主題目錄，管理頁只連過去。
3. 收工時更新狀態、證據連結、實作／驗證 commit 與下一步。只有找到實作時寫「有實作，待驗收」；測試通過須附實際範圍與結果。
4. `PHASES.md` 保留匯入時的歷史；新結論寫入 `STATUS.md` 並連到新的報告。規劃文字不等於已授權啟動，也不等於完成證據。

使用一般 Markdown 相對連結即可，不需要額外外掛。`⌘O` 可快速開啟 README、STATUS 或 PHASES；側邊欄搜尋與反向連結可查原始文件。

Obsidian 的 `.obsidian/` 設定與 `.trash/` 回收區留在本機，不進 Git。`docs/superpowers/` 原本有忽略規則，但本頁連結的 5A spec／plan 已受 Git 追蹤；新增其他計畫時須另確認是否納入版本管理。

專案根目錄的 `CLAUDE.md`、`AGENTS.md` 與 `Technotes/` 仍在 vault 外，由 IDE 查閱；不在此複製另一份。
