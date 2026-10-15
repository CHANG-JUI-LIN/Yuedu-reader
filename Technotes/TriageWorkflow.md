# 回報處理工作流（計畫，2026-10-15）

把使用者回饋、Firebase Crashlytics 和 Apple（TestFlight／Organizer）的問題收進同一個地方，
DeepSeek 逐筆先處理，Claude Code 每天早上讀過、對照程式碼找根因並提出修復，你決定要不要開工。

使用者的決定（2026-10-15）：
- Claude Code 每天早上在**這台 Mac 本機排程**跑一次（憑證都在本機，不上傳金鑰）。
- 嚴重問題用 **Telegram 機器人**即時通知。
- Apple 端接 **TestFlight 回饋（webhook 即時）＋ Organizer 診斷簽名（每天一次）**。

## 為什麼這樣分

DeepSeek 跑在 Cloud Functions 裡，每筆事件都會呼叫它，所以只做便宜、量大的工作：摘要、分級、併重複、回覆使用者。
它讀不到程式碼，也改不了程式。Claude Code 不是常駐服務，只在 session 執行時才看得到資料；
所以「即時」靠雲端收集＋Telegram，「修」靠每天的排程 session。

## 資料流

```
回饋中心 thread ──┐
Crashlytics 告警 ─┼─▶ Cloud Functions ─▶ triage/{id} ─▶ DeepSeek 摘要/分級/併重複
ASC webhook ──────┤                         │                   │
Organizer 簽名(每日)┘                        │                   └─▶ 嚴重 → Telegram
                                            ▼
                       每天早上本機排程：Claude Code /triage
                       讀 triage＋Crashlytics 堆疊＋程式碼 → 報告＋每項一張修復提案
```

`triage/{id}`（A 階段已實作：`functions/src/triage.ts`、`triagePolicy.ts`）：一個問題一筆。
- id：`crashlytics_<issueId>`（同一個 Crashlytics issue 的新崩潰／回歸／暴增／每日摘要都併進同一筆）、`feedback_<threadId>`。
  跨來源的「這則回饋＝那個崩潰」不在雲端猜，留給每天的 Claude Code 對照 `installIds`。
- 欄位：`source`、`lastKind`、`title`、`summary`（最新一次的說明）、`sourceRef`（Console 網址或回饋編號；
  **不放 thread 路徑**——路徑含收件匣金鑰，會跟著通知送進 Telegram）、
  `severity`（只升不降）、`status`（new／triaged／fixing／shipped／wontfix；回歸會把 shipped／wontfix 打回 new）、
  `threadPath`（只有回饋：thread 完整路徑，給每天的 Claude 讀整段對話和截圖；含收件匣金鑰，只存在這裡，通知不讀）、
  `triageNote`／`triagedAt`（每天的 Claude 寫）、
  `count`（活躍度分數，不是崩潰次數：回報／新 issue 各 +1、暴增加崩潰數、每日摘要加當天事件數，可能重疊）、`appVersions`、`installIds`、`firstSeenAt`／`lastSeenAt`、`eventIds`（最近 20 個，擋重送的事件）。
- 沒有 rules 條目，跟 `feedbackMeta` 一樣預設全拒，只有 admin 讀寫。

**關鍵接點**：回饋的 `installId` 就是 Crashlytics 的 userId（`CrashContext.installID`）。所以
「某人回報卡住」可以直接對上他那筆卡頓事件，報告裡同時有他的描述和堆疊。

## 階段

### A. 收件匣＋Crashlytics＋Telegram（程式完成，未部署）
1. 回饋中心：`onFeedbackThreadCreated` 寫完首回後寫一筆 triage。DeepSeek 在同一次呼叫多回一個
   `severity`（使用者看不到）；DeepSeek 失敗、或 severity 格式不對時這筆照樣進收件匣，分級記 `normal`
   （格式不對會記 warning，使用者的首回照常送出——severity 壞掉不准連累回覆）。
2. Crashlytics：`onNewFatalIssuePublished`（high）、`onRegressionAlertPublished`（high）、
   `onVelocityAlertPublished`（critical）、`onNewNonfatalIssuePublished`（normal，大多是 MetricKit 轉來的卡頓）、
   `onStabilityDigestPublished`（normal，累加次數）。名稱已對 firebase-functions 7.3.0 型別查證。
   Firebase Alerts 觸發器只能在 `global` 位置，所以這五個不設 region（其他函式都是 asia-east1）。
3. Telegram：第一次到 high／critical、或分級往上升時通知；回歸和暴增每次都通知。純文字（不用 parse mode）。
   通知失敗只記 log，不重試：項目已經在收件匣裡。

### B. Apple
1. ASC webhook 接收端（HTTPS function），用註冊時設定的 secret 驗簽；收到 TestFlight 回饋事件後，
   用 ASC API 抓詳情（截圖網址、裝置、崩潰紀錄 `crashLog`）寫 triage。
   事件型別名稱**尚未查證**，實作前讀 Apple 的 webhook 文件。
2. 每日排程函式：最新 build 的 `GET /v1/builds/{id}/diagnosticSignatures`，取新出現或權重上升的簽名，
   再抓 `GET /v1/diagnosticSignatures/{id}/logs` 寫 triage。
3. Secrets：ASC 金鑰（p8）、Key ID、Issuer ID。金鑰角色是否夠用，**要用實際呼叫確認**
   （有論壇回報部分端點要 Admin）。

### C. Claude Code 每日 /triage（已完成 2026-10-15）
1. Skill：`.claude/skills/triage/SKILL.md`。全部走 Firebase MCP（本機沒有 gcloud 憑證）：
   讀 `triage` 裡 new／triaged 的項目、Crashlytics 過去 24 小時 topIssues（補告警沒涵蓋的）、
   堆疊與回饋整段對話＋截圖，對照程式碼找根因，產出報告；每項能修的開一張 session 提案卡（不自動開工）；
   讀過的項目標 `triaged`＋`triageNote`。不改程式、不提交、不部署、不寫 `feedbackInboxes/`。
2. 排程：Claude 桌面 App 的排程任務 `yuedu-daily-triage`，每天 08:30（本機時間；App 沒開就等下次開啟時跑）。
3. 修好提交後標 `fixing`，上線後標 `shipped` 並擬回覆；回覆經你逐則確認才用 `functions/tools/feedback.ts reply` 送出
   （要先 `gcloud auth application-default login`）。
4. 查詢 `status IN … ORDER BY lastSeenAt DESC` 用的複合索引在 `firestore.indexes.json`。

## 需要你做的

- Telegram：在 BotFather 用 `/revoke` 換掉貼過的 token。然後**先在 Telegram 打開機器人按「開始」或傳一句話**，
  再開 `https://api.telegram.org/bot<新token>/getUpdates` 找 `"chat":{"id":…}`
  （回 `{"ok":true,"result":[]}` 表示機器人還沒收到任何訊息，傳一句後重新整理）。然後設：
  `firebase functions:secrets:set TELEGRAM_BOT_TOKEN`、`TELEGRAM_CHAT_ID`、`DEEPSEEK_API_KEY`。
  三個都設好才能部署：`onFeedbackThreadCreated` 現在也宣告了 Telegram 兩個 secret。
- App Store Connect 建 webhook（或給我有權限的 API 金鑰，我用 API 建）。
- 回覆使用者：裝 gcloud 後跑一次 `gcloud auth application-default login`，`tools/feedback.ts` 才能用。
- 每次部署前我會先問你；DeepSeek key（`DEEPSEEK_API_KEY`）還沒設，回饋中心也還沒部署。
- 防濫用（2026-10-15 定）：每個收件匣 24 小時內最多 10 則由 AI 助手回覆（`assistantRepliesPerInboxPerDay`），
  超過的照樣存、照樣進 triage（分級 normal，不發通知），只是不叫 DeepSeek、直接 queued。
