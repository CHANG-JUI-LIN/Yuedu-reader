import {ApiError} from "./errors.js";

/**
 * 回饋中心 through the relay: the clauses of `firestore.rules` (feedbackInboxes,
 * diagnosticReports) and `storage.rules` (feedback/) restated for requests the
 * relay writes with admin credentials, which bypass those rules. Free of Express
 * and Firebase so every clause is unit-tested. Keep in step with the rules files
 * and with `FeedbackFirestoreSchema` in the app; the rules stay in force for
 * builds that still write directly.
 */

export const FEEDBACK_LIMITS = {
  title: 200,
  preview: 300,
  text: 5000,
  attachments: 5,
  imageBytes: 15 * 1024 * 1024,
  videoBytes: 50 * 1024 * 1024,
  deviceInfoEntries: 20,
  deviceInfoValue: 500,
  diagnosticReportId: 20,
  /** appVersion, build, osVersion, device, locale, installId: not bounded by the rules. */
  shortField: 200,
  /** One bulk read marks at most this many threads. */
  readBatch: 200,
} as const;

export const DIAGNOSTIC_LIMITS = {
  /** Firestore caps a document at 1 MiB; the app keeps the payload under this. */
  payloadBytes: 900_000,
  note: 2000,
  scale: 1000,
} as const;

const INBOX_KEY = /^[A-Za-z0-9_-]{43}$/;
const DOCUMENT_ID = /^[0-9a-f-]{36}$/;
const FILE_NAME = /^[0-9a-f-]{36}\.[a-z0-9]{1,5}$/;
const EXTENSION = /^[a-z0-9]{1,5}$/;
const MEDIA_TYPE = /^(image|video)\/[a-z0-9][a-z0-9.+-]{0,60}$/;
const REPORT_ID = /^YD-[2-9A-HJKMNP-Z]{4}-[2-9A-HJKMNP-Z]{4}$/;

export type FeedbackKind = "bug" | "suggestion";
export type AttachmentKind = "image" | "video";

// MARK: - Identity

/**
 * The inbox key travels as `Authorization: Inbox <key>`, never in a URL or a
 * body: access logs record URLs, and the host proxy redacts Authorization.
 * Knowing the key is what grants access to the inbox (see firestore.rules).
 */
export function inboxKeyFromAuthorization(header: string | undefined): string {
  const match = /^Inbox\s+(\S+)$/.exec((header ?? "").trim());
  const key = match?.[1];
  if (key === undefined || !INBOX_KEY.test(key)) {
    throw new ApiError("unauthenticated", "A feedback inbox key is required.");
  }
  return key;
}

export function validThreadId(value: unknown): string {
  if (typeof value !== "string" || !DOCUMENT_ID.test(value)) {
    throw new ApiError("invalid-argument", "The thread id is not valid.");
  }
  return value;
}

export function validFileName(value: unknown): string {
  if (typeof value !== "string" || !FILE_NAME.test(value)) {
    throw new ApiError("invalid-argument", "The attachment name is not valid.");
  }
  return value;
}

export function attachmentObjectPath(inbox: string, threadId: string, fileName: string): string {
  return `feedback/${inbox}/${threadId}/${fileName}`;
}

// MARK: - Attachments

export interface UploadTarget {
  kind: AttachmentKind;
  contentType: string;
  extension: string;
  maxBytes: number;
}

/** What an upload may be: storage.rules' `image/*` ≤ 15 MB, `video/*` ≤ 50 MB. */
export function uploadTarget(contentType: unknown, extension: unknown): UploadTarget {
  const type = typeof contentType === "string" ? contentType.split(";")[0]?.trim().toLowerCase() ?? "" : "";
  if (!MEDIA_TYPE.test(type)) {
    throw new ApiError("unsupported-media-type", "Attachments must be images or videos.");
  }
  if (typeof extension !== "string" || !EXTENSION.test(extension)) {
    throw new ApiError("invalid-argument", "The attachment extension is not valid.");
  }
  const kind: AttachmentKind = type.startsWith("image/") ? "image" : "video";
  return {
    kind,
    contentType: type,
    extension,
    maxBytes: kind === "image" ? FEEDBACK_LIMITS.imageBytes : FEEDBACK_LIMITS.videoBytes,
  };
}

/** The declared length, refused before a byte is read when it is missing or too large. */
export function declaredUploadLength(header: string | undefined, maxBytes: number): number {
  const length = header === undefined ? Number.NaN : Number(header);
  if (!Number.isInteger(length) || length <= 0) {
    throw new ApiError("invalid-argument", "An upload needs a Content-Length.");
  }
  if (length > maxBytes) {
    throw new ApiError("payload-too-large", "The attachment exceeds the size limit.");
  }
  return length;
}

export interface AttachmentReference {
  path: string;
  fileName: string;
  width: number;
  height: number;
}

/** What Storage holds for an uploaded attachment, read back before it is cited. */
export interface StoredAttachment {
  contentType: string;
  bytes: number;
}

export interface AttachmentField {
  path: string;
  kind: AttachmentKind;
  contentType: string;
  bytes: number;
  width: number;
  height: number;
}

/**
 * A message may cite only attachments uploaded under its own inbox and thread.
 * Kind, type and size come from Storage, not from the client.
 */
function attachmentReferences(value: unknown, inbox: string, threadId: string): AttachmentReference[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new ApiError("invalid-argument", "attachments must be a list.");
  if (value.length > FEEDBACK_LIMITS.attachments) {
    throw new ApiError("invalid-argument", "Too many attachments.");
  }
  const prefix = `feedback/${inbox}/${threadId}/`;
  const seen = new Set<string>();
  return value.map((item: unknown) => {
    if (!isRecord(item) || typeof item.path !== "string" || !item.path.startsWith(prefix)) {
      throw new ApiError("permission-denied", "An attachment does not belong to this thread.");
    }
    const fileName = validFileName(item.path.slice(prefix.length));
    if (seen.has(fileName)) throw new ApiError("invalid-argument", "An attachment is listed twice.");
    seen.add(fileName);
    return {
      path: item.path,
      fileName,
      width: dimension(item.width),
      height: dimension(item.height),
    };
  });
}

export function attachmentField(reference: AttachmentReference, stored: StoredAttachment): AttachmentField {
  const target = uploadTarget(stored.contentType, "bin");
  return {
    path: reference.path,
    kind: target.kind,
    contentType: target.contentType,
    bytes: stored.bytes,
    width: reference.width,
    height: reference.height,
  };
}

// MARK: - Thread and message writes

export interface NewThread {
  threadId: string;
  kind: FeedbackKind;
  title: string;
  preview: string;
  text: string;
  attachments: AttachmentReference[];
  appVersion: string;
  build: string;
  osVersion: string;
  device: string;
  locale: string;
  installId: string;
  diagnosticReportId: string;
  deviceInfo: Record<string, string>;
}

/** firestore.rules `threads` create, plus its first message's create. */
export function sanitizeNewThread(body: unknown, inbox: string): NewThread {
  if (!isRecord(body)) throw new ApiError("invalid-argument", "A JSON object is required.");
  const threadId = validThreadId(body.threadId);
  if (body.kind !== "bug" && body.kind !== "suggestion") {
    throw new ApiError("invalid-argument", "kind must be bug or suggestion.");
  }
  const text = boundedString(body.text, FEEDBACK_LIMITS.text, "text").trim();
  if (text === "") throw new ApiError("invalid-argument", "A report needs a description.");
  return {
    threadId,
    kind: body.kind,
    title: boundedString(body.title, FEEDBACK_LIMITS.title, "title"),
    preview: boundedString(body.preview, FEEDBACK_LIMITS.preview, "preview"),
    text,
    attachments: attachmentReferences(body.attachments, inbox, threadId),
    appVersion: boundedString(body.appVersion, FEEDBACK_LIMITS.shortField, "appVersion"),
    build: boundedString(body.build, FEEDBACK_LIMITS.shortField, "build"),
    osVersion: boundedString(body.osVersion, FEEDBACK_LIMITS.shortField, "osVersion"),
    device: boundedString(body.device, FEEDBACK_LIMITS.shortField, "device"),
    locale: boundedString(body.locale, FEEDBACK_LIMITS.shortField, "locale"),
    installId: boundedString(body.installId, FEEDBACK_LIMITS.shortField, "installId"),
    diagnosticReportId: boundedString(body.diagnosticReportId, FEEDBACK_LIMITS.diagnosticReportId, "diagnosticReportId"),
    deviceInfo: deviceInfo(body.deviceInfo),
  };
}

export interface Reply {
  text: string;
  preview: string;
  attachments: AttachmentReference[];
}

/** firestore.rules `messages` create and the thread summary update that goes with it. */
export function sanitizeReply(body: unknown, inbox: string, threadId: string): Reply {
  if (!isRecord(body)) throw new ApiError("invalid-argument", "A JSON object is required.");
  const text = boundedString(body.text, FEEDBACK_LIMITS.text, "text").trim();
  const attachments = attachmentReferences(body.attachments, inbox, threadId);
  if (text === "" && attachments.length === 0) {
    throw new ApiError("invalid-argument", "A reply needs text or an attachment.");
  }
  return {text, preview: boundedString(body.preview, FEEDBACK_LIMITS.preview, "preview"), attachments};
}

/**
 * The one status change a reply makes: answering a 待補充 request puts the
 * thread back in the queue. Decided from the stored status, never the client's.
 */
export function statusAfterReply(current: unknown): string | null {
  return current === "needsInfo" ? "queued" : null;
}

/** A device that wants 回饋中心 push: its APNs token and which APNs host serves it. */
export interface PushDeviceRegistration {
  deviceId: string;
  token: string;
  environment: "development" | "production";
}

const APNS_TOKEN = /^[0-9a-f]{64,200}$/;

/**
 * `feedbackInboxes/{inbox}/pushDevices/{deviceId}`, read by `onFeedbackThreadUpdated`
 * (functions/src/feedbackPush.ts). The device id is the app's install id, lowercased, so
 * one device keeps one entry however often its token changes; an inbox shared over
 * iCloud Keychain gets one entry per device.
 */
export function sanitizePushDevice(deviceId: unknown, body: unknown): PushDeviceRegistration {
  if (typeof deviceId !== "string" || !DOCUMENT_ID.test(deviceId)) {
    throw new ApiError("invalid-argument", "Not a valid device id.");
  }
  if (!isRecord(body)) throw new ApiError("invalid-argument", "A JSON object is required.");
  if (typeof body.token !== "string" || !APNS_TOKEN.test(body.token)) {
    throw new ApiError("invalid-argument", "token must be a hex APNs device token.");
  }
  if (body.environment !== "development" && body.environment !== "production") {
    throw new ApiError("invalid-argument", "environment must be development or production.");
  }
  return {deviceId, token: body.token, environment: body.environment};
}

export function threadIdList(value: unknown): string[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > FEEDBACK_LIMITS.readBatch) {
    throw new ApiError("invalid-argument", `threadIds must list 1 to ${FEEDBACK_LIMITS.readBatch} threads.`);
  }
  return [...new Set(value.map(validThreadId))];
}

// MARK: - Responses

/** The thread fields the app reads (`FeedbackService.thread(id:data:)`), dates as ISO strings. */
export function threadPayload(id: string, data: Record<string, unknown>): Record<string, unknown> {
  return {
    id,
    number: typeof data.number === "number" ? data.number : null,
    kind: typeof data.kind === "string" ? data.kind : null,
    title: typeof data.title === "string" ? data.title : "",
    status: typeof data.status === "string" ? data.status : null,
    createdAt: isoDate(data.createdAt),
    updatedAt: isoDate(data.updatedAt),
    lastMessagePreview: typeof data.lastMessagePreview === "string" ? data.lastMessagePreview : "",
    lastMessageAuthor: typeof data.lastMessageAuthor === "string" ? data.lastMessageAuthor : null,
    lastReplyAt: isoDate(data.lastReplyAt),
    userLastReadAt: isoDate(data.userLastReadAt),
  };
}

export function messagePayload(id: string, data: Record<string, unknown>): Record<string, unknown> {
  const attachments = Array.isArray(data.attachments) ? data.attachments.filter(isRecord) : [];
  return {
    id,
    author: typeof data.author === "string" ? data.author : null,
    text: typeof data.text === "string" ? data.text : "",
    attachments: attachments.map((attachment) => ({
      path: typeof attachment.path === "string" ? attachment.path : "",
      kind: typeof attachment.kind === "string" ? attachment.kind : "",
      contentType: typeof attachment.contentType === "string" ? attachment.contentType : "",
      bytes: typeof attachment.bytes === "number" ? attachment.bytes : 0,
      width: typeof attachment.width === "number" ? attachment.width : 0,
      height: typeof attachment.height === "number" ? attachment.height : 0,
    })),
    createdAt: isoDate(data.createdAt),
  };
}

/** Firestore Timestamps (anything with `toDate()`) and Dates; everything else is null. */
export function isoDate(value: unknown): string | null {
  if (value instanceof Date) return value.toISOString();
  if (isRecord(value) && typeof value.toDate === "function") {
    const date: unknown = (value.toDate as () => unknown)();
    if (date instanceof Date) return date.toISOString();
  }
  return null;
}

// MARK: - Diagnostic reports

export interface DiagnosticReport {
  reportId: string;
  appVersion: string;
  build: string;
  osVersion: string;
  device: string;
  locale: string;
  installId: string;
  scale: string;
  note: string;
  payload: Buffer;
  payloadBytes: number;
  payloadEncoding: string;
  keptEntries: number;
  totalEntries: number;
}

/** firestore.rules `diagnosticReports` create. The payload arrives base64 and is stored as Bytes. */
export function sanitizeDiagnosticReport(body: unknown): DiagnosticReport {
  if (!isRecord(body)) throw new ApiError("invalid-argument", "A JSON object is required.");
  if (typeof body.reportId !== "string" || !REPORT_ID.test(body.reportId)) {
    throw new ApiError("invalid-argument", "The report id is not valid.");
  }
  if (typeof body.payload !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(body.payload)) {
    throw new ApiError("invalid-argument", "payload must be base64.");
  }
  const payload = Buffer.from(body.payload, "base64");
  if (payload.length === 0 || payload.length > DIAGNOSTIC_LIMITS.payloadBytes) {
    throw new ApiError("payload-too-large", "The diagnostic log exceeds the size limit.");
  }
  if (body.payloadEncoding !== "deflate-utf8") {
    throw new ApiError("invalid-argument", "payloadEncoding must be deflate-utf8.");
  }
  return {
    reportId: body.reportId,
    appVersion: boundedString(body.appVersion, FEEDBACK_LIMITS.shortField, "appVersion"),
    build: boundedString(body.build, FEEDBACK_LIMITS.shortField, "build"),
    osVersion: boundedString(body.osVersion, FEEDBACK_LIMITS.shortField, "osVersion"),
    device: boundedString(body.device, FEEDBACK_LIMITS.shortField, "device"),
    locale: boundedString(body.locale, FEEDBACK_LIMITS.shortField, "locale"),
    installId: boundedString(body.installId, FEEDBACK_LIMITS.shortField, "installId"),
    scale: boundedString(body.scale, DIAGNOSTIC_LIMITS.scale, "scale"),
    note: boundedString(body.note, DIAGNOSTIC_LIMITS.note, "note"),
    payload,
    payloadBytes: count(body.payloadBytes, "payloadBytes"),
    payloadEncoding: body.payloadEncoding,
    keptEntries: count(body.keptEntries, "keptEntries"),
    totalEntries: count(body.totalEntries, "totalEntries"),
  };
}

// MARK: - Helpers

function boundedString(value: unknown, limit: number, name: string): string {
  if (value === undefined) return "";
  if (typeof value !== "string") throw new ApiError("invalid-argument", `${name} must be a string.`);
  if (Array.from(value).length > limit) throw new ApiError("invalid-argument", `${name} is too long.`);
  return value;
}

function deviceInfo(value: unknown): Record<string, string> {
  if (value === undefined) return {};
  if (!isRecord(value)) throw new ApiError("invalid-argument", "deviceInfo must be an object.");
  const entries = Object.entries(value);
  if (entries.length > FEEDBACK_LIMITS.deviceInfoEntries) {
    throw new ApiError("invalid-argument", "deviceInfo has too many entries.");
  }
  const result: Record<string, string> = {};
  for (const [key, entry] of entries) {
    if (!/^[A-Za-z0-9_]{1,40}$/.test(key)) throw new ApiError("invalid-argument", "deviceInfo has an invalid key.");
    result[key] = boundedString(entry, FEEDBACK_LIMITS.deviceInfoValue, `deviceInfo.${key}`);
  }
  return result;
}

function dimension(value: unknown): number {
  if (value === undefined) return 0;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 100_000) {
    throw new ApiError("invalid-argument", "An attachment dimension is not valid.");
  }
  return value;
}

function count(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new ApiError("invalid-argument", `${name} must be a non-negative integer.`);
  }
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
