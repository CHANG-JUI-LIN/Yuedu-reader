// The pure half of the triage inbox (Technotes/TriageWorkflow.md): how a Crashlytics
// alert or a feedback thread becomes a `triage/{id}` item, how a repeat merges into the
// item it repeats, and when the developer is pinged on Telegram. `triage.ts` does the I/O.

export type TriageSource = "feedback" | "crashlytics" | "testflight" | "organizer";

/// critical: the app is unusable or losing data for many people, act today.
/// high: a crash or a broken main feature. normal: worth a look. low: cosmetic or an idea.
export const triageSeverities = ["low", "normal", "high", "critical"] as const;
export type TriageSeverity = (typeof triageSeverities)[number];

export function severityRank(severity: TriageSeverity): number {
  return triageSeverities.indexOf(severity);
}

export function higherSeverity(a: TriageSeverity, b: TriageSeverity): TriageSeverity {
  return severityRank(a) >= severityRank(b) ? a : b;
}

/// What happened, as far as notifying goes. A regression or a velocity spike is news even
/// when the item already exists; anything else pings only the first time it reaches high.
export type TriageEventKind =
  | "feedback"
  | "newFatal"
  | "newNonfatal"
  | "regression"
  | "velocity"
  | "stabilityDigest"
  | "testflightCrash"
  | "testflightFeedback"
  | "diagnosticSignature";

/// One observation of a problem, before it is merged into the inbox.
export interface TriageObservation {
  /// Stable across repeats of the same problem; also the document id.
  id: string;
  source: TriageSource;
  kind: TriageEventKind;
  title: string;
  summary: string;
  severity: TriageSeverity;
  /// An activity score, not a crash count: one per report or new issue, a velocity
  /// alert's crash count, a digest's daily event count (which can overlap the velocity).
  count: number;
  appVersion: string;
  /// Where to look: a Crashlytics console URL, or the feedback thread's number. This goes
  /// into the Telegram ping, so it never holds a thread path: the path contains the
  /// inbox key, which is what grants access to that user's inbox.
  sourceRef: string;
  /// Feedback only: the reporter's install, which is also their Crashlytics user id.
  installId?: string;
  /// Feedback only: the thread's Firestore path, so the daily run can read the whole
  /// conversation and its attachments. It contains the inbox key, so it is stored on the
  /// item and nowhere else — `telegramMessage` never reads it.
  threadPath?: string;
  /// Long evidence the daily run reads and the ping never carries: a TestFlight crash
  /// log, an Organizer call stack.
  detail?: string;
  /// Storage paths of copies the daily run can open (TestFlight screenshots, whose
  /// Apple URLs expire).
  attachmentPaths?: string[];
}

/// The fields of an existing item that a new observation is merged against.
export interface TriageItemState {
  severity: TriageSeverity;
  status: string;
}

/// The item's status after an observation: a regression reopens a fixed problem.
export function mergedStatus(existing: TriageItemState | null, kind: TriageEventKind): string {
  if (existing === null) return "new";
  if (kind === "regression" && (existing.status === "shipped" || existing.status === "wontfix")) {
    return "new";
  }
  return existing.status;
}

export function shouldNotify(
  existing: TriageItemState | null,
  observation: Pick<TriageObservation, "kind" | "severity">
): boolean {
  if (observation.kind === "regression" || observation.kind === "velocity") return true;
  if (severityRank(observation.severity) < severityRank("high")) return false;
  return existing === null || severityRank(existing.severity) < severityRank(observation.severity);
}

/// Crashlytics issue ids are hex; feedback thread ids are UUIDs. Both are safe as
/// document ids once prefixed, which also keeps the two sources from colliding.
export function crashlyticsItemId(issueId: string): string {
  return `crashlytics_${issueId}`;
}

export function feedbackItemId(threadId: string): string {
  return `feedback_${threadId}`;
}

export function crashlyticsConsoleURL(projectId: string, appId: string, issueId: string): string {
  return `https://console.firebase.google.com/v1/appid/project/${projectId}/crashlytics/app/${appId}/issues/${issueId}`;
}

interface CrashlyticsIssue {
  id: string;
  title: string;
  subtitle: string;
  appVersion: string;
}

type CrashlyticsKind = "newFatal" | "newNonfatal" | "regression" | "velocity" | "stabilityDigest";

const crashlyticsSeverity: Record<CrashlyticsKind, TriageSeverity> = {
  newFatal: "high",
  regression: "high",
  velocity: "critical",
  // Mostly MetricKit's hangs and resource exceptions, forwarded as non-fatals: the daily
  // read covers them; they do not page anyone.
  newNonfatal: "normal",
  stabilityDigest: "normal",
};

export function crashlyticsObservation(input: {
  kind: CrashlyticsKind;
  issue: CrashlyticsIssue;
  projectId: string;
  appId: string;
  count?: number;
  detail?: string;
}): TriageObservation {
  const {kind, issue} = input;
  const summary = [issue.subtitle, input.detail].filter((part) => part && part.length > 0).join("\n");
  return {
    id: crashlyticsItemId(issue.id),
    source: "crashlytics",
    kind,
    title: issue.title,
    summary,
    severity: crashlyticsSeverity[kind],
    count: input.count ?? 1,
    appVersion: issue.appVersion,
    sourceRef: crashlyticsConsoleURL(input.projectId, input.appId, issue.id),
  };
}

/// A feedback thread, graded by the model's severity, or `normal` when there is no grade.
export function feedbackObservation(input: {
  threadId: string;
  number: number | undefined;
  title: string;
  text: string;
  severity: TriageSeverity | null;
  appVersion: string;
  installId?: string;
  threadPath: string;
}): TriageObservation {
  const number = input.number ?? "?";
  return {
    id: feedbackItemId(input.threadId),
    source: "feedback",
    kind: "feedback",
    title: `#${number} ${input.title}`,
    summary: Array.from(input.text).slice(0, 1000).join(""),
    severity: input.severity ?? "normal",
    count: 1,
    appVersion: input.appVersion,
    sourceRef: `回饋中心 #${number}（npx tsx tools/feedback.ts show ${number}）`,
    ...(input.installId !== undefined ? {installId: input.installId} : {}),
    threadPath: input.threadPath,
  };
}

const severityLabel: Record<TriageSeverity, string> = {
  critical: "🔴 緊急",
  high: "🟠 嚴重",
  normal: "🟡 一般",
  low: "⚪️ 低",
};

const kindLabel: Record<TriageEventKind, string> = {
  feedback: "使用者回饋",
  newFatal: "Crashlytics 新崩潰",
  newNonfatal: "Crashlytics 新的非嚴重問題",
  regression: "Crashlytics 回歸（修好過又出現）",
  velocity: "Crashlytics 崩潰暴增",
  stabilityDigest: "Crashlytics 每日穩定度摘要",
  testflightCrash: "TestFlight 崩潰回報",
  testflightFeedback: "TestFlight 回饋",
  diagnosticSignature: "Organizer 診斷簽名",
};

/// Telegram's sendMessage caps text at 4096 characters.
export const telegramTextLimit = 4096;

/// The ping, plain text (no parse mode, so nothing in a title needs escaping).
export function telegramMessage(observation: TriageObservation): string {
  const lines = [
    `${severityLabel[observation.severity]}｜${kindLabel[observation.kind]}`,
    observation.title,
  ];
  if (observation.summary.length > 0) lines.push("", observation.summary);
  lines.push("", `版本 ${observation.appVersion.length > 0 ? observation.appVersion : "未知"}`);
  if (observation.count > 1) lines.push(`次數 ${observation.count}`);
  lines.push(observation.sourceRef);
  const text = lines.join("\n");
  return text.length <= telegramTextLimit ? text : `${text.slice(0, telegramTextLimit - 1)}…`;
}
