// The pure half of 回饋中心's first reply: what the model is told, the shape it must
// answer in, and how its answer becomes thread fields. `feedbackTriage.ts` does the I/O.

import {TriageSeverity, triageSeverities} from "./triagePolicy.js";

export type FeedbackKind = "bug" | "suggestion";

/// Thread statuses, as the app's `FeedbackStatus` reads them. The client creates a
/// thread as `received`; the first reply moves it to `queued` or `needsInfo`.
export type FeedbackStatus = "received" | "queued" | "processing" | "needsInfo" | "done";

export const triageStatuses = ["queued", "needsInfo"] as const;
export type TriageStatus = (typeof triageStatuses)[number];

export interface TriageInput {
  kind: FeedbackKind;
  text: string;
  locale: string;
  appVersion: string;
  osVersion: string;
  device: string;
  imageCount: number;
  videoCount: number;
}

export interface TriageResult {
  title: string;
  reply: string;
  status: TriageStatus;
  /// For the developer's triage inbox only; the user never sees it. Null when the model
  /// broke this field's shape: the reply and status do not depend on it, so a bad
  /// severity must not cost the user their reply (the caller records `normal` and logs).
  severity: TriageSeverity | null;
}

export const triageSystemPrompt = `You are the support assistant of 閱讀 (Yuedu Reader), an iOS reader app for EPUB, TXT, PDF, comics, RSS and web novels fetched through user-imported source configurations (called 來源配置 in the app — never call them 書源 or "book sources").

A user has just sent a bug report or a suggestion from the app's feedback center. Write the first reply they will see, and pick the report's status.

The reply:
- Write in the user's language and script. A user writing Traditional Chinese gets Traditional Chinese; never switch to Simplified. The device locale is a hint when the text is too short to tell.
- Restate the problem in one sentence so they know it was understood, then say what happens next.
- If something essential is missing, ask for exactly that, as a short numbered list of at most three items: the steps to reproduce, the book or source configuration involved, the page or screen, what they expected, or a screen recording. Only ask for what is actually missing.
- For a suggestion, thank them and say it has been recorded for the developer to consider.
- Two to five sentences. Plain text, no Markdown headings or bold. Do not promise a fix or a date. Do not invent features, settings or workarounds. You are an assistant, not the developer — do not speak as the developer.

The status: needsInfo when you asked for something; otherwise queued.

The title: a few words naming the problem or idea, in the user's language, like a bug tracker title, at most 20 characters.

The severity, for the developer only (the user never sees it):
- critical: the app crashes on launch, or books, reading progress, notes or purchases are lost.
- high: a crash, or a main feature (opening or reading a book, search, sync, listening) does not work.
- normal: a feature misbehaves but there is a way around it, or the report is too vague to tell.
- low: a cosmetic issue, wording, or a suggestion.
Judge by what the report shows, not by how upset the user sounds.

Answer with one JSON object and nothing else, in this shape:
{"title": "海報牆名稱顯示簡體", "reply": "...", "status": "queued", "severity": "low"}
status is either "queued" or "needsInfo"; severity is one of "critical", "high", "normal", "low".`;

/// The user turn: the report itself, with the device facts that decide what is missing.
export function triageUserMessage(input: TriageInput): string {
  const attachments: string[] = [];
  if (input.imageCount > 0) attachments.push(`${input.imageCount} screenshot(s), shown above`);
  if (input.videoCount > 0) attachments.push(`${input.videoCount} screen recording(s), not shown`);
  return [
    `Report type: ${input.kind === "bug" ? "bug report" : "suggestion"}`,
    `Device locale: ${input.locale}`,
    `App ${input.appVersion}, ${input.osVersion}, ${input.device}`,
    `Attachments: ${attachments.length > 0 ? attachments.join("; ") : "none"}`,
    "",
    "<report>",
    input.text,
    "</report>",
  ].join("\n");
}

/// Validates the model's JSON. DeepSeek's JSON mode guarantees valid JSON, not the shape,
/// so every field is checked.
export function parseTriage(raw: string): TriageResult {
  const value = JSON.parse(raw) as Partial<TriageResult>;
  const title = (value.title ?? "").trim();
  const reply = (value.reply ?? "").trim();
  if (reply.length === 0) throw new Error("triage reply is empty");
  if (!triageStatuses.includes(value.status as TriageStatus)) {
    throw new Error(`triage status ${String(value.status)} is not a triage status`);
  }
  return {
    title: Array.from(title).slice(0, 40).join(""),
    reply,
    status: value.status as TriageStatus,
    severity: triageSeverities.includes(value.severity as TriageSeverity) ? value.severity as TriageSeverity : null,
  };
}

/// The AI 助手 answers at most this many reports per inbox in a rolling day. Reports past
/// it are still stored and queued for the developer, just without the model's reply: no
/// sign-in stands between a script and DeepSeek's bill (maintainer, 2026-10-15).
export const assistantRepliesPerInboxPerDay = 10;

/// `threadsInLastDay` counts the new thread itself.
export function assistantMayReply(threadsInLastDay: number): boolean {
  return threadsInLastDay <= assistantRepliesPerInboxPerDay;
}

/// The thread's list preview: the first line of a message, bounded like the client's.
export function messagePreview(text: string): string {
  const firstLines = text.trim().split(/\s*\n\s*/).join(" ");
  return Array.from(firstLines).slice(0, 120).join("");
}
