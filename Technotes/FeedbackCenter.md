# 回饋中心 (Feedback Center)

Replaced 設定 → 進階 → 診斷與回報 on 2026-10-15. Two-way: a report becomes a thread the
person can follow, answer and close; the developer and an AI 助手 reply in it.

## Screens (`Modules/Features/Feedback/`)

| Screen | File | Notes |
| --- | --- | --- |
| 回饋中心 | `FeedbackCenterView` | 回饋與改進, 我的回饋 (unread badge), 截圖後顯示意見回饋入口 toggle, 診斷紀錄 (the old log viewer, `DiagnosticsView`) |
| 回饋與改進 | `FeedbackComposeView` | 問題回報／改進建議, text, ≤5 images/videos, 設備資訊, 提交反饋, 在其他應用程式中開啟 (log file with the report as preface), 僅上傳日誌 |
| 我的回饋 | `FeedbackListView` | bottom-bar segmented 處理中／排隊中／待補充／已完成 + sort menu, 全部已讀 |
| 回饋 #n | `FeedbackThreadView` | bubbles (mine trailing; AI 助手／開發者 leading), 標記已解決, floating composer |
| screenshot card | `FeedbackScreenshotPrompt` | own `UIWindow` sized to the card, so it shows over the full-screen reader; the form is presented from the topmost view controller |

Status text is always the client's `FeedbackStatus` enum through `localized()`, never server
text, so a zh-Hant user never sees a Simplified status.

## Identity

No sign-in. `FeedbackInbox.key` is 32 random bytes (base64url, 43 chars) in iCloud Keychain
(`com.yuedu.feedbackInbox`, synchronizable). Knowing the key is the read permission — the
inbox path is the capability, like an unguessable link. There is no collection-group rule,
so a client cannot enumerate inboxes.

## Data

```
feedbackInboxes/{inboxKey}/threads/{uuid}            thread summary
feedbackInboxes/{inboxKey}/threads/{uuid}/messages/{id}
feedbackMeta/counter                                 next thread number (admin only)
Storage feedback/{inboxKey}/{threadUUID}/{file}      attachments (image ≤15 MB, video ≤50 MB)
diagnosticReports/YD-XXXX-XXXX                       the log sent with a report (thread.diagnosticReportId)
```

Client-writable fields are whitelisted in `firestore.rules`; `FeedbackFirestoreSchema` holds
the same lists and `FeedbackFirestoreSchemaTests` reads the rules file to keep them equal.
A client may create a thread (status `received`) with its first message in one batch, add
its own messages, mark read, mark `done`, and move `needsInfo` → `queued` by answering.

## Developer side

- `functions/src/feedbackTriage.ts` `onFeedbackThreadCreated` (asia-east1): assigns the
  thread number, then asks DeepSeek (`deepseek-flash` = DeepSeek-V4.1-Flash, which reads the
  screenshots; thinking off, JSON mode) for the first reply, title and `queued`/`needsInfo`.
  Secret `DEEPSEEK_API_KEY`. On any failure the thread moves to `queued` with no reply and the
  error is logged — the report itself is already stored.
- `functions/tools/feedback.ts`: `list`, `show`, `reply`, `status` with admin credentials
  (`gcloud auth application-default login`). Needs the collection-group indexes in
  `firestore.indexes.json`.

## Deploy

```bash
firebase functions:secrets:set DEEPSEEK_API_KEY
firebase deploy --only firestore:rules,firestore:indexes,storage,functions:onFeedbackThreadCreated
```
