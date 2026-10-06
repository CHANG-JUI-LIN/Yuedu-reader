---
title: 目標：每本測試 EPUB 和 WebView 至少八成相似
updated: 2026-10-07
status: 凍結；只有人可以改
tags: [yuedu, browser-layout, fidelity-loop]
---

# 目標

[首頁](README.md) · [量法](ORACLE.md) · [已知差距](GAPS.md)

**`~/Desktop/Test document/EPUB Format` 裡的每一本 EPUB，用閱讀器渲染的結果和 WKWebView 渲染的結果，相似度至少 80 分。**

分數的定義在 [ORACLE.md](ORACLE.md)。資料夾裡有什麼書就量什麼書；之後放進新書會自動納入。

## 完成的條件

全部成立才算完成。每一條都能用指令檢查。

- [ ] 從**主工作目錄**執行下面的指令，對象是要驗收的閱讀器程式樹，結束碼為 0：
  ```bash
  bash scripts/fidelity/measure.sh --sets dev,holdout --tree <要驗收的 Yuedu-reader> --require-goal
  ```
  也就是：每本書 ≥ 80 分，閱讀器這邊沒有任何一章擷取失敗，而且每本書抽到的章節至少一半量得到（WebView 自己畫不出來的章節不算分，規則見 [ORACLE.md](ORACLE.md)「分數」）。
- [ ] 每本書 holdout 的分數不比 dev 低超過 8 分。低很多代表修法只對看過的章節有效。
- [ ] [README.md](README.md)「改了排版要跑的測試」全部通過。
- [ ] 低於 60 分的章節逐一列在最後的報告裡，由使用者決定要不要另外處理。

## 規則

- 量法不跟著引擎修改一起改：`scripts/fidelity/`、`RenderFidelityOracleTests.swift`、`ORACLE.md` 和這份目標由 `scripts/fidelity/oracle.lock` 鎖住，改法見 [ORACLE.md](ORACLE.md)「改量法」。
- 回退舊引擎的章節分數低，解法是讓新引擎支援它用到的 CSS，不是回頭修舊引擎。
- 已錄製的基線與 golden 要更新，必須先有根因與正確性證據，並由人確認（[PHASES.md](../PHASES.md) D-09）。
- 不為某一本書、某個 class 名稱、某個檔名寫特判。實作的是 CSS／HTML 的通用規則，書只是問題來源與回歸樣本（[PHASES.md](../PHASES.md) D-01）。

## 不做

- 不追求逐像素相同
- 不處理翻頁特有的行為、固定版面 EPUB、互動與選字
- 不做載入效能優化與 Lexbor 切換；它們是各自的主線。但為了分數做的修改不能讓載入明顯變慢
