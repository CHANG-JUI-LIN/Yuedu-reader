import {Transform} from "node:stream";
import {pipeline} from "node:stream/promises";
import {randomUUID} from "node:crypto";

import {Router, type Request} from "express";
import {FieldValue} from "firebase-admin/firestore";

import type {GatewayContext} from "../context.js";
import {ApiError, errorBody} from "../errors.js";
import {
  attachmentField,
  attachmentObjectPath,
  declaredUploadLength,
  inboxKeyFromAuthorization,
  messagePayload,
  sanitizeDiagnosticReport,
  sanitizeNewThread,
  sanitizePushDevice,
  sanitizeReply,
  statusAfterReply,
  threadIdList,
  threadPayload,
  uploadTarget,
  validFileName,
  validThreadId,
  type AttachmentField,
  type AttachmentReference,
} from "../feedbackPolicy.js";
import {logError} from "../logger.js";

/**
 * 回饋中心 for networks where Firestore and Storage are unreachable: the same
 * `feedbackInboxes/{inbox}/threads` documents and `feedback/{inbox}/…` objects
 * the app used to write directly, so `onFeedbackThreadCreated` and
 * `functions/tools/feedback.ts` see no difference. Every request names its inbox
 * with `Authorization: Inbox <key>`; `feedbackPolicy.ts` holds the rules.
 */
export function feedbackRouter(context: GatewayContext): Router {
  const router = Router();
  const threads = (inbox: string) =>
    context.firestore.collection("feedbackInboxes").doc(inbox).collection("threads");

  router.get("/threads", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const snapshot = await threads(inbox).get();
      response.json({threads: snapshot.docs.map((document) => threadPayload(document.id, document.data()))});
    } catch (error) {
      next(firestoreError(error));
    }
  });

  router.get("/threads/:threadId/messages", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const threadId = validThreadId(request.params.threadId);
      const snapshot = await threads(inbox).doc(threadId).collection("messages").orderBy("createdAt").get();
      response.json({messages: snapshot.docs.map((document) => messagePayload(document.id, document.data()))});
    } catch (error) {
      next(firestoreError(error));
    }
  });

  // A new report: the thread and its first message in one batch, so the
  // first-reply function always finds the message. `create` refuses an id
  // that already exists.
  router.post("/threads", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const report = sanitizeNewThread(request.body, inbox);
      const attachments = await storedAttachments(context, report.attachments);
      const now = FieldValue.serverTimestamp();
      const thread = threads(inbox).doc(report.threadId);
      const batch = context.firestore.batch();
      batch.create(thread, {
        kind: report.kind,
        title: report.title,
        status: "received",
        createdAt: now,
        updatedAt: now,
        lastMessageAt: now,
        lastMessagePreview: report.preview,
        lastMessageAuthor: "user",
        userLastReadAt: now,
        appVersion: report.appVersion,
        build: report.build,
        osVersion: report.osVersion,
        device: report.device,
        locale: report.locale,
        installId: report.installId,
        diagnosticReportId: report.diagnosticReportId,
        deviceInfo: report.deviceInfo,
      });
      batch.create(thread.collection("messages").doc(randomUUID()), {
        author: "user",
        text: report.text,
        attachments,
        createdAt: now,
      });
      await batch.commit();
      response.status(201).json({threadId: report.threadId});
    } catch (error) {
      next(firestoreError(error));
    }
  });

  router.post("/threads/:threadId/messages", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const threadId = validThreadId(request.params.threadId);
      const reply = sanitizeReply(request.body, inbox, threadId);
      const attachments = await storedAttachments(context, reply.attachments);
      const thread = threads(inbox).doc(threadId);
      await context.firestore.runTransaction(async (transaction) => {
        const current = await transaction.get(thread);
        if (!current.exists) throw new ApiError("not-found", "No such thread.");
        const now = FieldValue.serverTimestamp();
        const next = statusAfterReply(current.get("status"));
        transaction.create(thread.collection("messages").doc(randomUUID()), {
          author: "user",
          text: reply.text,
          attachments,
          createdAt: now,
        });
        transaction.update(thread, {
          updatedAt: now,
          lastMessageAt: now,
          lastMessagePreview: reply.preview,
          lastMessageAuthor: "user",
          userLastReadAt: now,
          ...(next === null ? {} : {status: next}),
        });
      });
      response.status(201).json({threadId});
    } catch (error) {
      next(firestoreError(error));
    }
  });

  router.post("/threads/:threadId/resolve", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const threadId = validThreadId(request.params.threadId);
      const now = FieldValue.serverTimestamp();
      // `userResolvedAt` tells `onFeedbackThreadUpdated` the user did this, so they get no push for it.
      await threads(inbox).doc(threadId).update({status: "done", updatedAt: now, userResolvedAt: now});
      response.json({threadId});
    } catch (error) {
      next(firestoreError(error));
    }
  });

  // Registers (or refreshes) this device's APNs token for the inbox's push: a reply from
  // the developer or the AI 助手, or a move to 待補充／已完成 (functions/src/feedbackPush.ts).
  router.put("/push-devices/:deviceId", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const device = sanitizePushDevice(request.params.deviceId, request.body);
      await context.firestore.collection("feedbackInboxes").doc(inbox)
        .collection("pushDevices").doc(device.deviceId)
        .set({token: device.token, environment: device.environment, updatedAt: FieldValue.serverTimestamp()});
      response.status(204).end();
    } catch (error) {
      next(firestoreError(error));
    }
  });

  // Marks threads read. Ids the inbox does not hold are skipped rather than
  // failing the rest: the list the client sends can be a moment old.
  router.post("/read", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const ids = threadIdList(isRecord(request.body) ? request.body.threadIds : undefined);
      const references = ids.map((id) => threads(inbox).doc(id));
      const snapshots = await context.firestore.getAll(...references);
      const existing = snapshots.filter((snapshot) => snapshot.exists);
      if (existing.length > 0) {
        const batch = context.firestore.batch();
        for (const snapshot of existing) {
          batch.update(snapshot.ref, {userLastReadAt: FieldValue.serverTimestamp()});
        }
        await batch.commit();
      }
      response.json({read: existing.map((snapshot) => snapshot.id)});
    } catch (error) {
      next(firestoreError(error));
    }
  });

  // Streams the body into Storage as it arrives, so a 50 MB video never sits in
  // memory. The object name is chosen here and created only if absent
  // (storage.rules: create-only). A body longer than declared or over the limit
  // aborts the upload, and Storage keeps nothing.
  router.put("/threads/:threadId/attachments", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const threadId = validThreadId(request.params.threadId);
      const target = uploadTarget(request.header("content-type"), request.query.extension);
      const declared = declaredUploadLength(request.header("content-length"), target.maxBytes);
      const fileName = `${randomUUID()}.${target.extension}`;
      const path = attachmentObjectPath(inbox, threadId, fileName);
      let received = 0;
      const counter = new Transform({
        transform(chunk: Buffer, _encoding, callback) {
          received += chunk.length;
          if (received > declared) {
            callback(new ApiError("payload-too-large", "The attachment exceeds its declared size."));
            return;
          }
          callback(null, chunk);
        },
      });
      const file = context.storage.bucket().file(path);
      await pipeline(
        request,
        counter,
        file.createWriteStream({
          resumable: false,
          contentType: target.contentType,
          preconditionOpts: {ifGenerationMatch: 0},
          metadata: {cacheControl: "private, max-age=86400"},
        })
      );
      response.status(201).json({path, kind: target.kind, contentType: target.contentType, bytes: received});
    } catch (error) {
      next(storageError(error));
    }
  });

  router.get("/threads/:threadId/attachments/:fileName", async (request, response, next) => {
    try {
      const inbox = inboxOf(request);
      const path = attachmentObjectPath(
        inbox,
        validThreadId(request.params.threadId),
        validFileName(request.params.fileName)
      );
      const file = context.storage.bucket().file(path);
      const [metadata] = await file.getMetadata();
      response.setHeader("Content-Type", String(metadata.contentType ?? "application/octet-stream"));
      if (metadata.size !== undefined) response.setHeader("Content-Length", String(metadata.size));
      response.setHeader("Cache-Control", "private, max-age=86400");
      await pipeline(file.createReadStream(), response);
    } catch (error) {
      if (response.headersSent) {
        logError("feedback attachment download broke off", error);
        response.destroy();
        return;
      }
      next(storageError(error));
    }
  });

  router.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown feedback route.");
    response.status(error.status).json(errorBody(error));
  });

  return router;
}

/**
 * `diagnosticReports/{id}`: the redacted, compressed log a report or 診斷紀錄
 * sends. Create-only, as in firestore.rules; nothing is readable back.
 */
export function diagnosticsRouter(context: GatewayContext): Router {
  const router = Router();

  router.post("/reports", async (request, response, next) => {
    try {
      const report = sanitizeDiagnosticReport(request.body);
      await context.firestore.collection("diagnosticReports").doc(report.reportId).create({
        ...report,
        createdAt: FieldValue.serverTimestamp(),
      });
      response.status(201).json({reportId: report.reportId});
    } catch (error) {
      next(firestoreError(error));
    }
  });

  router.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown diagnostics route.");
    response.status(error.status).json(errorBody(error));
  });

  return router;
}

function inboxOf(request: Request): string {
  return inboxKeyFromAuthorization(request.header("authorization"));
}

/** Kind, type and size of each cited attachment, read from Storage. */
async function storedAttachments(
  context: GatewayContext,
  references: AttachmentReference[]
): Promise<AttachmentField[]> {
  return Promise.all(references.map(async (reference) => {
    try {
      const [metadata] = await context.storage.bucket().file(reference.path).getMetadata();
      return attachmentField(reference, {
        contentType: String(metadata.contentType ?? ""),
        bytes: Number(metadata.size ?? 0),
      });
    } catch (error) {
      if (upstreamCode(error) === 404) {
        throw new ApiError("invalid-argument", "An attachment was not uploaded.");
      }
      throw storageError(error);
    }
  }));
}

/** Firestore's gRPC codes the app tells apart; anything else is the generic handler's 500. */
function firestoreError(error: unknown): unknown {
  if (error instanceof ApiError) return error;
  switch (upstreamCode(error)) {
    case 5: return new ApiError("not-found", "No such thread.");
    case 6: return new ApiError("conflict", "That item already exists.");
    case 4:
    case 14: return new ApiError("upstream-unavailable", "The feedback service is unreachable. Try again.");
    default: return error;
  }
}

/** Storage answers with HTTP statuses: 404 missing, 412 a create-only name already taken. */
function storageError(error: unknown): unknown {
  if (error instanceof ApiError) return error;
  switch (upstreamCode(error)) {
    case 404: return new ApiError("not-found", "No such attachment.");
    case 412: return new ApiError("conflict", "That attachment already exists.");
    case 503: return new ApiError("upstream-unavailable", "The feedback service is unreachable. Try again.");
    default: return error;
  }
}

function upstreamCode(error: unknown): number | null {
  if (error === null || typeof error !== "object") return null;
  const code = (error as {code?: unknown}).code;
  return typeof code === "number" ? code : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
