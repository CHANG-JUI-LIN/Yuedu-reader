import {FieldValue, Timestamp, getFirestore} from "firebase-admin/firestore";
import {getStorage} from "firebase-admin/storage";
import {logger} from "firebase-functions";
import {defineSecret} from "firebase-functions/params";
import {onDocumentCreated} from "firebase-functions/v2/firestore";

import {
  FeedbackKind,
  TriageResult,
  assistantMayReply,
  messagePreview,
  parseTriage,
  triageSystemPrompt,
  triageUserMessage,
} from "./feedbackTriagePolicy.js";
import {recordObservation, triageSecrets} from "./triage.js";
import {feedbackObservation} from "./triagePolicy.js";

const deepSeekApiKey = defineSecret("DEEPSEEK_API_KEY");

/// The same service and model the app's own DeepSeek preset uses
/// (`AIProviderPreset`): `deepseek-flash` is DeepSeek-V4.1-Flash, which reads images
/// (https://api-docs.deepseek.com/guides/vision). Thinking is off: this is a short,
/// mechanical reply, and DeepSeek otherwise thinks at high and bills it.
const deepSeekEndpoint = "https://api.deepseek.com/v1/chat/completions";
const deepSeekModel = "deepseek-flash";

/// Screenshots the model looks at. The app sends JPEGs at most 2048 px on a side, far
/// inside DeepSeek's per-image limits; five is the app's own attachment ceiling.
const maxTriageImages = 5;

interface AttachmentField {
  path?: string;
  kind?: string;
  contentType?: string;
}

/// 回饋中心: a new thread gets its number (#25,743 in the list) and the AI 助手's first
/// reply, which also sets the status to `queued` or `needsInfo`.
///
/// The client writes the thread and its first message in one batch, so the message is
/// there when this runs. Both steps are idempotent — a thread that already has a
/// number keeps it, and the reply is written only while the status is still
/// `received` — because Firestore triggers can be delivered more than once.
///
/// The model sees the report's screenshots; recordings it is only told about.
///
/// An inbox past `assistantRepliesPerInboxPerDay` gets no model reply: the thread is moved
/// to `queued` as when the model is unreachable, and the developer answers it.
///
/// When the model cannot be reached (no key, an API error, malformed JSON) the thread
/// is moved to `queued` without a reply and the failure is logged: the report itself is
/// safe in Firestore and the developer answers it as usual.
///
/// Either way the report also goes into the developer's triage inbox (`triage.ts`), graded
/// by the model's severity — or `normal` when there is no model answer, or the answer's
/// severity is malformed (logged; the user's reply is kept either way).
export const onFeedbackThreadCreated = onDocumentCreated(
  {
    document: "feedbackInboxes/{inboxId}/threads/{threadId}",
    region: "asia-east1",
    secrets: [deepSeekApiKey, ...triageSecrets],
    timeoutSeconds: 120,
  },
  async (event) => {
    const snapshot = event.data;
    if (snapshot === undefined) return;
    const db = getFirestore();
    const threadRef = snapshot.ref;

    await assignNumber(threadRef);

    const thread = (await threadRef.get()).data();
    if (thread === undefined || thread.status !== "received") return;

    const messages = await threadRef.collection("messages").orderBy("createdAt").limit(1).get();
    const first = messages.docs[0]?.data();
    if (first === undefined) {
      logger.warn("feedback thread has no first message", {thread: threadRef.path});
      return;
    }
    const attachments = (first.attachments ?? []) as AttachmentField[];

    const dayAgo = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
    const threadsInLastDay = (await threadRef.parent.where("createdAt", ">=", dayAgo).count().get()).data().count;
    const mayReply = assistantMayReply(threadsInLastDay);
    if (!mayReply) {
      logger.warn("feedback inbox over the daily assistant limit", {thread: threadRef.path, threadsInLastDay});
    }

    let triage: TriageResult | null = null;
    if (mayReply) {
      try {
        const images = await loadImages(attachments);
        triage = await runTriage(images, triageUserMessage({
          kind: thread.kind as FeedbackKind,
          text: String(first.text ?? ""),
          locale: String(thread.locale ?? ""),
          appVersion: `${thread.appVersion ?? ""} (${thread.build ?? ""})`,
          osVersion: String(thread.osVersion ?? ""),
          device: String(thread.device ?? ""),
          imageCount: images.length,
          videoCount: attachments.filter((attachment) => attachment.kind === "video").length,
        }));
      } catch (error) {
        logger.error("feedback triage failed", {thread: threadRef.path, error: String(error)});
      }
    }

    await db.runTransaction(async (transaction) => {
      const current = await transaction.get(threadRef);
      if (current.get("status") !== "received") return;
      if (triage === null) {
        transaction.update(threadRef, {status: "queued"});
        return;
      }
      // A fixed id: a second delivery of this event overwrites rather than duplicates.
      transaction.set(threadRef.collection("messages").doc("triage"), {
        author: "assistant",
        text: triage.reply,
        attachments: [],
        createdAt: FieldValue.serverTimestamp(),
      });
      transaction.update(threadRef, {
        status: triage.status,
        ...(triage.title.length > 0 ? {title: triage.title} : {}),
        lastMessageAt: FieldValue.serverTimestamp(),
        lastMessagePreview: messagePreview(triage.reply),
        lastMessageAuthor: "assistant",
        lastReplyAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });

    if (triage !== null && triage.severity === null) {
      logger.warn("feedback triage returned no valid severity; recording normal", {thread: threadRef.path});
    }
    const text = String(first.text ?? "");
    await recordObservation(feedbackObservation({
      threadId: threadRef.id,
      number: (await threadRef.get()).get("number") as number | undefined,
      title: triage?.title || String(thread.title ?? "") || messagePreview(text),
      text,
      severity: triage?.severity ?? null,
      appVersion: `${thread.appVersion ?? ""} (${thread.build ?? ""})`,
      ...(typeof thread.installId === "string" ? {installId: thread.installId} : {}),
    }), event.id);
  }
);

/// Thread numbers count up from one counter document no client can read or write.
async function assignNumber(threadRef: FirebaseFirestore.DocumentReference): Promise<void> {
  const db = getFirestore();
  const counterRef = db.collection("feedbackMeta").doc("counter");
  await db.runTransaction(async (transaction) => {
    const thread = await transaction.get(threadRef);
    if (typeof thread.get("number") === "number") return;
    const counter = await transaction.get(counterRef);
    const next = (counter.get("next") as number | undefined) ?? 1;
    transaction.set(counterRef, {next: next + 1}, {merge: true});
    transaction.update(threadRef, {number: next});
  });
}

interface DeepSeekResponse {
  choices?: Array<{message?: {content?: string | null}; finish_reason?: string}>;
  error?: {message?: string};
}

/// The report's screenshots as data URLs, read from Storage with admin credentials.
async function loadImages(attachments: AttachmentField[]): Promise<string[]> {
  const bucket = getStorage().bucket();
  const images = attachments
    .filter((attachment) => attachment.kind === "image" && typeof attachment.path === "string")
    .slice(0, maxTriageImages);
  const urls: string[] = [];
  for (const image of images) {
    const [data] = await bucket.file(image.path as string).download();
    urls.push(`data:${image.contentType ?? "image/jpeg"};base64,${data.toString("base64")}`);
  }
  return urls;
}

async function runTriage(imageURLs: string[], userMessage: string): Promise<TriageResult> {
  const response = await fetch(deepSeekEndpoint, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${deepSeekApiKey.value()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: deepSeekModel,
      messages: [
        {role: "system", content: triageSystemPrompt},
        {
          role: "user",
          // Images go in the user turn only; DeepSeek returns 400 for images elsewhere.
          content: [
            ...imageURLs.map((url) => ({type: "image_url", image_url: {url}})),
            {type: "text", text: userMessage},
          ],
        },
      ],
      thinking: {type: "disabled"},
      response_format: {type: "json_object"},
      max_tokens: 2000,
      temperature: 0.3,
    }),
    signal: AbortSignal.timeout(90_000),
  });
  const body = (await response.json()) as DeepSeekResponse;
  if (!response.ok) {
    throw new Error(`DeepSeek HTTP ${response.status}: ${body.error?.message ?? "no message"}`);
  }
  const choice = body.choices?.[0];
  if (choice?.finish_reason !== "stop") {
    throw new Error(`DeepSeek finished with ${choice?.finish_reason ?? "no choice"}`);
  }
  return parseTriage(choice.message?.content ?? "");
}
