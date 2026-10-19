import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {logger} from "firebase-functions";
import {defineSecret} from "firebase-functions/params";
import {onDocumentUpdated} from "firebase-functions/v2/firestore";

import {APNsClient} from "./apns.js";
import {apnsPayload, feedbackPushFor, pushDevice, tokenIsDead} from "./feedbackPushPolicy.js";

/// The APNs auth key (Certificates, Identifiers & Profiles › Keys, with Apple Push
/// Notifications service enabled) and the team it belongs to.
const apnsTeamId = defineSecret("APNS_TEAM_ID");
const apnsKeyId = defineSecret("APNS_KEY_ID");
const apnsPrivateKey = defineSecret("APNS_PRIVATE_KEY");

/// 回饋中心 push: a reply from the developer or the AI 助手, or a move to 待補充／已完成,
/// reaches every device the inbox registered (`pushDevices`, written by the Gateway).
///
/// One trigger on the thread document covers every writer — the AI 助手's first reply
/// (`feedbackTriage.ts`), `tools/feedback.ts reply|status`, the Gateway's resolve — because
/// each of them updates the thread; `feedbackPushFor` decides from before and after.
///
/// Firestore triggers can be delivered more than once, so each event claims
/// `feedbackPushEvents/{eventId}` before sending, and a second delivery finds it taken.
export const onFeedbackThreadUpdated = onDocumentUpdated(
  {
    document: "feedbackInboxes/{inboxId}/threads/{threadId}",
    region: "asia-east1",
    secrets: [apnsTeamId, apnsKeyId, apnsPrivateKey],
  },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before === undefined || after === undefined) return;
    const push = feedbackPushFor(before, after);
    if (push === null) return;

    const db = getFirestore();
    const inboxRef = db.collection("feedbackInboxes").doc(event.params.inboxId);
    const devices = await inboxRef.collection("pushDevices").get();
    if (devices.empty) return;

    try {
      await db.collection("feedbackPushEvents").doc(event.id).create({
        thread: event.data?.after.ref.path,
        kind: push.kind,
        createdAt: FieldValue.serverTimestamp(),
      });
    } catch (error) {
      if ((error as {code?: unknown}).code === 6) return; // ALREADY_EXISTS: delivered before.
      throw error;
    }

    const payload = apnsPayload(push, event.params.threadId, typeof after.title === "string" ? after.title : "");
    const client = new APNsClient({
      teamId: apnsTeamId.value().trim(),
      keyId: apnsKeyId.value().trim(),
      privateKey: apnsPrivateKey.value(),
    });
    try {
      await Promise.all(devices.docs.map(async (document) => {
        const device = pushDevice(document.data());
        if (device === null) {
          logger.warn("feedback push: malformed device entry removed", {device: document.ref.path});
          await document.ref.delete();
          return;
        }
        try {
          const result = await client.send(device, payload, `${event.params.threadId}:${push.kind}`);
          if (result.status === 200) return;
          if (tokenIsDead(result.status, result.reason)) {
            logger.info("feedback push: token retired", {device: document.ref.path, reason: result.reason});
            await document.ref.delete();
            return;
          }
          logger.error("feedback push refused", {
            device: document.ref.path, status: result.status, reason: result.reason,
          });
        } catch (error) {
          logger.error("feedback push failed", {device: document.ref.path, error: String(error)});
        }
      }));
    } finally {
      client.close();
    }
  }
);
