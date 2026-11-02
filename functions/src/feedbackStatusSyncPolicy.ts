// 回饋中心 status from the developer's triage inbox: which thread status a `triage/` item's
// status means for the user who reported it. Pure, so the trigger
// (`feedbackStatusSync.ts`) and its tests share one rule.

import {FeedbackStatus} from "./feedbackTriagePolicy.js";

/// The thread status a triage status asks for, or null when it asks for nothing.
///
/// - `fixing` / `fixed` → 處理中: a fix that is committed but not released is still in
///   progress for the user, who has the bug until the build reaches them (maintainer,
///   2026-11-03).
/// - `shipped` → 已完成, which also sends the 已完成 push (`feedbackPushPolicy.ts`).
/// - `new` / `triaged` leave the AI 助手's 排隊中／待補充 alone, and `wontfix` waits for the
///   developer's reply, which explains it and sets 已完成 itself (`feedback.ts reply
///   --status done`): 已完成 with no word on why reads as being brushed off.
export function threadStatusForTriage(triageStatus: unknown): FeedbackStatus | null {
  switch (triageStatus) {
  case "fixing":
  case "fixed":
    return "processing";
  case "shipped":
    return "done";
  default:
    return null;
  }
}

/// The write a triage status makes to a thread now at `current`: forward only, so a thread
/// never leaves 已完成 (the user's own 標記為已完成, or the developer's) and an item moving
/// back from `fixed` to `triaged` does not take 處理中 away.
export function threadStatusAfterTriage(current: unknown, triageStatus: unknown): FeedbackStatus | null {
  const target = threadStatusForTriage(triageStatus);
  if (target === null) return null;
  return progress(current) < progress(target) ? target : null;
}

/// received, queued and needsInfo are all before anyone picked the report up; an unknown
/// value counts as that too, as the app reads it (`FeedbackStatus(serverValue:)`).
function progress(status: unknown): number {
  switch (status) {
  case "processing": return 1;
  case "done": return 2;
  default: return 0;
  }
}
