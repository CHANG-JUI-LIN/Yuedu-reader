// The pure half of the Apple side of the triage inbox (Technotes/TriageWorkflow.md, phase B):
// verifying an App Store Connect webhook delivery, and turning TestFlight feedback and
// Organizer diagnostic signatures into triage observations. `appleTriage.ts` does the I/O.

import {createHash, createHmac, timingSafeEqual} from "node:crypto";

import {TriageObservation} from "./triagePolicy.js";

/// App Store Connect signs each delivery with the webhook's secret and sends
/// `x-apple-signature: hmacsha256=<hex HMAC-SHA256 of the raw body>`.
export function verifyAppleSignature(rawBody: Buffer, header: string | undefined, secret: string): boolean {
  const prefix = "hmacsha256=";
  if (header === undefined || !header.startsWith(prefix)) return false;
  const received = Buffer.from(header.slice(prefix.length), "hex");
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  return received.length === expected.length && timingSafeEqual(received, expected);
}

export interface WebhookEvent {
  /// The event's own id: a redelivery carries the same one.
  eventId: string;
  type: string;
  instanceId: string | null;
}

export function parseWebhookEvent(rawBody: string): WebhookEvent {
  const body = JSON.parse(rawBody) as {
    data?: {id?: string; type?: string; relationships?: {instance?: {data?: {id?: string}; id?: string}}};
  };
  const data = body.data;
  if (typeof data?.id !== "string" || typeof data.type !== "string") {
    throw new Error("webhook body has no data.id or data.type");
  }
  const instance = data.relationships?.instance;
  return {eventId: data.id, type: data.type, instanceId: instance?.data?.id ?? instance?.id ?? null};
}

export type TestFlightKind = "testflightCrash" | "testflightFeedback";

/// The two webhook events this inbox takes; every other type is acknowledged and ignored.
export function testFlightKind(eventType: string): TestFlightKind | null {
  switch (eventType) {
  case "betaFeedbackCrashSubmissionCreated": return "testflightCrash";
  case "betaFeedbackScreenshotSubmissionCreated": return "testflightFeedback";
  default: return null;
  }
}

/// The attributes both submission types share, as far as the inbox uses them. The
/// tester's email is deliberately not read: the inbox does not need to know who.
export interface TestFlightSubmission {
  comment?: string;
  deviceModel?: string;
  osVersion?: string;
  locale?: string;
  appUptimeInMilliseconds?: number;
}

/// A crash log can run to hundreds of KB; the first part holds the exception and the
/// crashed thread, and a Firestore document caps at 1 MiB.
export const maxDetailLength = 200_000;

function firstLine(text: string, limit: number): string {
  const line = text.trim().split(/\n/)[0] ?? "";
  return Array.from(line).slice(0, limit).join("");
}

export function testFlightObservation(input: {
  kind: TestFlightKind;
  submissionId: string;
  submission: TestFlightSubmission;
  appVersion: string;
  crashLog?: string;
  screenshotPaths: string[];
}): TriageObservation {
  const {kind, submission} = input;
  const comment = (submission.comment ?? "").trim();
  const crash = kind === "testflightCrash";
  const device = [submission.deviceModel, submission.osVersion, submission.locale]
    .filter((part) => part !== undefined && part.length > 0).join(" · ");
  const summary = [Array.from(comment).slice(0, 1000).join(""), device].filter((part) => part.length > 0).join("\n");
  return {
    // Each submission is its own item: testers report separately, and the daily run
    // groups the ones that are the same bug.
    id: `testflight_${input.submissionId}`,
    source: "testflight",
    kind,
    title: comment.length > 0 ? firstLine(comment, 40) : (crash ? "TestFlight 崩潰（沒有留言）" : "TestFlight 回饋（沒有留言）"),
    summary,
    // A tester's crash pings; screenshot feedback waits for the daily read.
    severity: crash ? "high" : "normal",
    count: 1,
    appVersion: input.appVersion,
    sourceRef: `App Store Connect › TestFlight › ${crash ? "崩潰" : "回饋"} ${input.submissionId}`,
    ...(input.crashLog !== undefined ? {detail: input.crashLog.slice(0, maxDetailLength)} : {}),
    ...(input.screenshotPaths.length > 0 ? {attachmentPaths: input.screenshotPaths} : {}),
  };
}

export type DiagnosticType = "HANGS" | "DISK_WRITES" | "LAUNCHES";

export interface DiagnosticSignature {
  id: string;
  diagnosticType: DiagnosticType;
  signature: string;
  /// The signature's share of this build's reports of its type, 0…1.
  weight: number;
}

/// Signatures below this share are noise next to the ones above it.
export const minSignatureWeight = 0.05;

export function signaturesWorthRecording(signatures: DiagnosticSignature[]): DiagnosticSignature[] {
  return signatures
    .filter((signature) => signature.weight >= minSignatureWeight)
    .sort((a, b) => b.weight - a.weight);
}

const diagnosticLabel: Record<DiagnosticType, string> = {
  HANGS: "卡頓",
  DISK_WRITES: "大量寫入",
  LAUNCHES: "啟動慢",
};

/// One item per signature across builds: Apple's signature ids are per build, so the
/// id hashes the type and the signature text instead.
export function diagnosticItemId(signature: Pick<DiagnosticSignature, "diagnosticType" | "signature">): string {
  const hash = createHash("sha256").update(`${signature.diagnosticType}\n${signature.signature}`).digest("hex");
  return `organizer_${hash.slice(0, 32)}`;
}

export function diagnosticObservation(input: {
  signature: DiagnosticSignature;
  appVersion: string;
  insights: string[];
  callStack: string;
}): TriageObservation {
  const {signature} = input;
  const share = `佔這個 build ${diagnosticLabel[signature.diagnosticType]}回報的 ${Math.round(signature.weight * 100)}%`;
  return {
    id: diagnosticItemId(signature),
    source: "organizer",
    kind: "diagnosticSignature",
    title: Array.from(`${diagnosticLabel[signature.diagnosticType]}：${signature.signature}`).slice(0, 120).join(""),
    summary: [share, ...input.insights].join("\n"),
    // Aggregated performance data: the daily run weighs it, nothing pings.
    severity: "normal",
    count: 1,
    appVersion: input.appVersion,
    sourceRef: "Xcode Organizer › " + diagnosticLabel[signature.diagnosticType],
    ...(input.callStack.length > 0 ? {detail: input.callStack.slice(0, maxDetailLength)} : {}),
  };
}

export interface CallStackNode {
  rawFrame?: string;
  isBlameFrame?: boolean;
  sampleCount?: number;
  subFrames?: CallStackNode[];
}

export interface DiagnosticLogsResponse {
  productData?: Array<{
    diagnosticInsights?: Array<{insightsString?: string}>;
    diagnosticLogs?: Array<{
      diagnosticMetaData?: Record<string, string>;
      callStackTree?: Array<{callStacks?: Array<{callStackRootFrames?: CallStackNode[]}>}>;
    }>;
  }>;
}

export function diagnosticInsights(logs: DiagnosticLogsResponse): string[] {
  return (logs.productData ?? [])
    .flatMap((product) => product.diagnosticInsights ?? [])
    .map((insight) => insight.insightsString ?? "")
    .filter((text) => text.length > 0);
}

const maxStackFrames = 60;

/// The first log's metadata and its heaviest path through the call stack tree: at each
/// level the subframe with the most samples, which is where the time went. Frames the
/// app is responsible for are marked with ▶.
export function summarizeDiagnosticLogs(logs: DiagnosticLogsResponse): string {
  const log = logs.productData?.[0]?.diagnosticLogs?.[0];
  if (log === undefined) return "";
  const lines = Object.entries(log.diagnosticMetaData ?? {}).map(([key, value]) => `${key}: ${value}`);
  const roots = log.callStackTree?.[0]?.callStacks?.[0]?.callStackRootFrames ?? [];
  let frame = heaviest(roots);
  let depth = 0;
  if (frame !== undefined) lines.push("");
  while (frame !== undefined && depth < maxStackFrames) {
    lines.push(`${frame.isBlameFrame ? "▶ " : "  "}${frame.rawFrame ?? "?"}`);
    frame = heaviest(frame.subFrames ?? []);
    depth += 1;
  }
  return lines.join("\n");
}

function heaviest(frames: CallStackNode[]): CallStackNode | undefined {
  return frames.reduce<CallStackNode | undefined>(
    (best, frame) => (best === undefined || (frame.sampleCount ?? 0) > (best.sampleCount ?? 0) ? frame : best),
    undefined
  );
}
