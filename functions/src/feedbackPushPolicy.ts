/// 回饋中心 push: which thread writes tell the user something, and what the notification
/// says. Pure, so the trigger (`feedbackPush.ts`) and its tests share one rule.

/// What changed for the user. One notification per write, even when a reply and a status
/// change land together (`tools/feedback.ts reply … --status done`, the AI 助手's first
/// reply with `needsInfo`).
export type FeedbackPushKind = "reply" | "needsInfo" | "done";

export interface FeedbackPush {
  kind: FeedbackPushKind;
  /// The reply's first lines when there is a reply; the status line otherwise.
  preview: string | null;
}

export type ThreadFields = Record<string, unknown>;

/// A write the user should hear about: a reply from the developer or the AI 助手
/// (`lastReplyAt` moved — only those writers set it), or the status moving to 待補充 or
/// 已完成. 排隊中／處理中 are internal progress and stay quiet (maintainer, 2026-10-19).
///
/// The user's own 標記為已完成 (`resolve` in the Gateway) is not news to them: that write
/// moves `userResolvedAt`, and nothing else does.
export function feedbackPushFor(before: ThreadFields, after: ThreadFields): FeedbackPush | null {
  const replied = !sameInstant(before.lastReplyAt, after.lastReplyAt) && after.lastReplyAt != null;
  const statusMoved = before.status !== after.status;
  const userResolved = !sameInstant(before.userResolvedAt, after.userResolvedAt);
  const noticedStatus = statusMoved && !userResolved && (after.status === "needsInfo" || after.status === "done")
    ? after.status as "needsInfo" | "done"
    : null;

  if (replied) {
    const preview = typeof after.lastMessagePreview === "string" ? after.lastMessagePreview : "";
    return {kind: noticedStatus ?? "reply", preview: preview.length > 0 ? preview : null};
  }
  if (noticedStatus !== null) return {kind: noticedStatus, preview: null};
  return null;
}

/// Localizable.strings keys the app carries for each kind (every `.lproj`).
export const subtitleKeys: Record<FeedbackPushKind, string> = {
  reply: "回饋推播：新回覆",
  needsInfo: "回饋推播：待補充",
  done: "回饋推播：已完成",
};
export const statusBodyKeys: Record<FeedbackPushKind, string> = {
  reply: "回饋推播：新回覆內文",
  needsInfo: "回饋推播：待補充內文",
  done: "回饋推播：已完成內文",
};

/// The payload key the app routes a tap on: the thread to open.
export const threadPayloadKey = "feedbackThread";

/// The APNs body. The thread's title is the user's own words (or the AI's title in their
/// language), so it goes as is — or not at all, and iOS shows the app's name; the subtitle and a status-only body are localized on the
/// device. No `badge`: RSS owns the app badge (`RSSNotificationManager.updateBadge`).
export function apnsPayload(push: FeedbackPush, threadId: string, threadTitle: string): Record<string, unknown> {
  const alert: Record<string, unknown> = {"subtitle-loc-key": subtitleKeys[push.kind]};
  if (threadTitle.length > 0) alert.title = threadTitle;
  if (push.preview !== null) {
    alert.body = push.preview;
  } else {
    alert["loc-key"] = statusBodyKeys[push.kind];
  }
  return {
    "aps": {alert, "sound": "default", "thread-id": threadId},
    [threadPayloadKey]: threadId,
  };
}

/// A device the app registered through the Gateway (`feedbackInboxes/{inbox}/pushDevices`).
export interface PushDevice {
  token: string;
  environment: "development" | "production";
}

export function pushDevice(data: ThreadFields): PushDevice | null {
  const token = data.token;
  const environment = data.environment;
  if (typeof token !== "string" || !/^[0-9a-f]{64,200}$/.test(token)) return null;
  if (environment !== "development" && environment !== "production") return null;
  return {token, environment};
}

/// APNs answers that mean the token will never work again, so the device entry goes
/// (https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns).
export function tokenIsDead(status: number, reason: string | undefined): boolean {
  if (status === 410) return true;
  return status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic");
}

export function apnsHost(environment: PushDevice["environment"]): string {
  return environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
}

function sameInstant(a: unknown, b: unknown): boolean {
  return millis(a) === millis(b);
}

/// Firestore Timestamps in the trigger, Dates in tests; both expose the instant.
function millis(value: unknown): number | null {
  if (value == null) return null;
  if (value instanceof Date) return value.getTime();
  if (typeof value === "object" && typeof (value as {toMillis?: unknown}).toMillis === "function") {
    return (value as {toMillis(): number}).toMillis();
  }
  return null;
}
