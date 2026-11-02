import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {logger} from "firebase-functions";
import {onDocumentUpdated} from "firebase-functions/v2/firestore";

import {threadStatusAfterTriage} from "./feedbackStatusSyncPolicy.js";

/// 回饋中心 follows the triage inbox: when a feedback item's status changes in
/// `triage/{id}` — a fix session claiming it, a commit marking it fixed, a release marking
/// it shipped — the reporter's thread at its `threadPath` moves to match.
///
/// Before this, the two statuses were separate fields and nothing carried one to the other:
/// items marked `fixing` / `fixed` left their threads at 排隊中 or 待補充, and only a thread
/// someone also ran `tools/feedback.ts status` on ever showed 已完成.
///
/// One trigger on the item covers every writer — the triage skill, fix sessions, the daily
/// git-trailer sync, edits in the console. Nothing writes `triage/` on a thread update, so the
/// thread write here (which `onFeedbackThreadUpdated` sees, and pushes for 已完成) cannot loop.
export const onTriageItemUpdated = onDocumentUpdated(
  {document: "triage/{itemId}", region: "asia-east1"},
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before === undefined || after === undefined) return;
    if (before.status === after.status) return;
    const threadPath = after.threadPath;
    if (typeof threadPath !== "string" || !threadPath.startsWith("feedbackInboxes/")) return;

    const db = getFirestore();
    const threadRef = db.doc(threadPath);
    // Read inside the transaction: the policy decides from the thread's current status, and a
    // redelivered event finds the status already moved and writes nothing.
    await db.runTransaction(async (transaction) => {
      const thread = await transaction.get(threadRef);
      if (!thread.exists) {
        logger.warn("feedback status sync: thread is gone", {item: event.params.itemId, thread: threadPath});
        return;
      }
      const next = threadStatusAfterTriage(thread.get("status"), after.status);
      if (next === null) return;
      transaction.update(threadRef, {status: next, updatedAt: FieldValue.serverTimestamp()});
      logger.info("feedback status sync", {item: event.params.itemId, from: thread.get("status"), to: next});
    });
  }
);
