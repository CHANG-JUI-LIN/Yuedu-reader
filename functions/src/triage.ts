import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {logger} from "firebase-functions";
import {defineSecret} from "firebase-functions/params";
import {
  onNewFatalIssuePublished,
  onNewNonfatalIssuePublished,
  onRegressionAlertPublished,
  onStabilityDigestPublished,
  onVelocityAlertPublished,
} from "firebase-functions/v2/alerts/crashlytics";

import {
  TriageItemState,
  TriageObservation,
  TriageSeverity,
  crashlyticsObservation,
  higherSeverity,
  mergedStatus,
  shouldNotify,
  telegramMessage,
} from "./triagePolicy.js";

// The developer's triage inbox (Technotes/TriageWorkflow.md). Every report — a feedback
// thread, a Crashlytics alert — lands in `triage/{id}`, one item per problem, and the
// serious ones ping Telegram. The daily Claude Code run reads the inbox. Like
// `feedbackMeta`, `triage` has no rule in firestore.rules, so no client can reach it.

const telegramBotToken = defineSecret("TELEGRAM_BOT_TOKEN");
const telegramChatId = defineSecret("TELEGRAM_CHAT_ID");
export const triageSecrets = [telegramBotToken, telegramChatId];

/// Merges an observation into its item and pings Telegram when `shouldNotify` says so.
///
/// `eventId` is the delivering event's id. Event triggers can be delivered more than
/// once; an item that already took this event is left alone, so a repeat neither counts
/// twice nor pings twice.
export async function recordObservation(observation: TriageObservation, eventId: string): Promise<void> {
  const db = getFirestore();
  const itemRef = db.collection("triage").doc(observation.id);
  const notify = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(itemRef);
    const existing: TriageItemState | null = snapshot.exists
      ? {severity: snapshot.get("severity") as TriageSeverity, status: String(snapshot.get("status"))}
      : null;
    const eventIds = (snapshot.get("eventIds") as string[] | undefined) ?? [];
    if (eventIds.includes(eventId)) return false;

    const severity = existing === null ? observation.severity : higherSeverity(existing.severity, observation.severity);
    transaction.set(itemRef, {
      source: observation.source,
      lastKind: observation.kind,
      title: observation.title,
      summary: observation.summary,
      sourceRef: observation.sourceRef,
      severity,
      status: mergedStatus(existing, observation.kind),
      count: FieldValue.increment(observation.count),
      appVersions: FieldValue.arrayUnion(observation.appVersion),
      ...(observation.installId !== undefined ? {installIds: FieldValue.arrayUnion(observation.installId)} : {}),
      ...(observation.threadPath !== undefined ? {threadPath: observation.threadPath} : {}),
      ...(observation.detail !== undefined ? {detail: observation.detail} : {}),
      ...(observation.attachmentPaths !== undefined ? {attachmentPaths: observation.attachmentPaths} : {}),
      // The last few events only: enough to recognise a redelivery, which comes soon after.
      eventIds: [...eventIds, eventId].slice(-20),
      lastSeenAt: FieldValue.serverTimestamp(),
      ...(existing === null ? {firstSeenAt: FieldValue.serverTimestamp()} : {}),
    }, {merge: true});
    return shouldNotify(existing, observation);
  });
  if (notify) await sendTelegram(telegramMessage(observation));
}

/// A failed ping is logged, not thrown: the item is already in the inbox, and the daily
/// run reads it whether or not the ping went out.
async function sendTelegram(text: string): Promise<void> {
  try {
    const response = await fetch(`https://api.telegram.org/bot${telegramBotToken.value()}/sendMessage`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({chat_id: telegramChatId.value(), text, disable_web_page_preview: true}),
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) {
      const body = (await response.json().catch((error) => ({parseError: String(error)}))) as unknown;
      logger.error("telegram sendMessage failed", {status: response.status, body});
    }
  } catch (error) {
    logger.error("telegram sendMessage failed", {error: String(error)});
  }
}

function projectId(): string {
  const id = process.env.GCLOUD_PROJECT;
  if (id === undefined || id.length === 0) throw new Error("GCLOUD_PROJECT is not set");
  return id;
}

// Crashlytics alerts. Firebase Alerts triggers live in the "global" location (firebase-tools
// rejects any other), so these take no region, unlike the rest of this codebase.

export const onCrashlyticsNewFatal = onNewFatalIssuePublished({secrets: triageSecrets}, async (event) => {
  await recordObservation(crashlyticsObservation({
    kind: "newFatal", issue: event.data.payload.issue, projectId: projectId(), appId: event.appId,
  }), event.id);
});

export const onCrashlyticsNewNonfatal = onNewNonfatalIssuePublished({secrets: triageSecrets}, async (event) => {
  await recordObservation(crashlyticsObservation({
    kind: "newNonfatal", issue: event.data.payload.issue, projectId: projectId(), appId: event.appId,
  }), event.id);
});

export const onCrashlyticsRegression = onRegressionAlertPublished({secrets: triageSecrets}, async (event) => {
  const payload = event.data.payload;
  await recordObservation(crashlyticsObservation({
    kind: "regression", issue: payload.issue, projectId: projectId(), appId: event.appId,
    detail: `${payload.type}，上次標為已解決：${payload.resolveTime}`,
  }), event.id);
});

export const onCrashlyticsVelocity = onVelocityAlertPublished({secrets: triageSecrets}, async (event) => {
  const payload = event.data.payload;
  await recordObservation(crashlyticsObservation({
    kind: "velocity", issue: payload.issue, projectId: projectId(), appId: event.appId,
    count: payload.crashCount,
    detail: `${payload.crashCount} 次崩潰，佔該版本工作階段 ${payload.crashPercentage}%，首見於 ${payload.firstVersion}`,
  }), event.id);
});

export const onCrashlyticsStabilityDigest = onStabilityDigestPublished({secrets: triageSecrets}, async (event) => {
  const payload = event.data.payload;
  for (const trending of payload.trendingIssues) {
    await recordObservation(crashlyticsObservation({
      kind: "stabilityDigest", issue: trending.issue, projectId: projectId(), appId: event.appId,
      count: trending.eventCount,
      detail: `${payload.digestDate} 趨勢：${trending.type}，${trending.eventCount} 次、${trending.userCount} 位使用者`,
    }), event.id);
  }
});
