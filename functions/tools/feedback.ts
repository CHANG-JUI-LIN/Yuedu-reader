// 回饋中心, the developer side: list threads, read one, reply, change its status.
//
// Runs with admin credentials (Application Default Credentials):
//   gcloud auth application-default login      # once
//   cd functions
//   npx tsx tools/feedback.ts list [received|queued|processing|needsInfo|done]
//   npx tsx tools/feedback.ts show <number>
//   npx tsx tools/feedback.ts reply <number> "回覆內容" [--status processing|needsInfo|done]
//   npx tsx tools/feedback.ts status <number> <status>
//
// <number> is the #25,743 the user sees. A reply appears in the app as the developer's,
// marks the thread unread for its owner, and moves the summary the list shows.
// A reply, or a status moved to needsInfo or done, also reaches the owner's devices as a
// push (functions/src/feedbackPush.ts) — one notification even when both happen at once.
// Attachments are printed as gs:// paths; `gsutil cp` fetches them.

import {initializeApp} from "firebase-admin/app";
import {FieldValue, Timestamp, getFirestore} from "firebase-admin/firestore";

import {FeedbackStatus, messagePreview} from "../src/feedbackTriagePolicy.js";

const statuses: FeedbackStatus[] = ["received", "queued", "processing", "needsInfo", "done"];

initializeApp({projectId: process.env.GCLOUD_PROJECT ?? "yuedu-readerr"});
const db = getFirestore();

function stamp(value: unknown): string {
  return value instanceof Timestamp ? value.toDate().toLocaleString() : "-";
}

async function threadByNumber(number: number): Promise<FirebaseFirestore.QueryDocumentSnapshot> {
  const result = await db.collectionGroup("threads").where("number", "==", number).limit(1).get();
  const thread = result.docs[0];
  if (thread === undefined) throw new Error(`no thread #${number}`);
  return thread;
}

function parseStatus(value: string | undefined): FeedbackStatus {
  if (value === undefined || !statuses.includes(value as FeedbackStatus)) {
    throw new Error(`status must be one of ${statuses.join(", ")}`);
  }
  return value as FeedbackStatus;
}

async function list(status?: string): Promise<void> {
  let query: FirebaseFirestore.Query = db.collectionGroup("threads");
  if (status !== undefined) query = query.where("status", "==", parseStatus(status));
  const result = await query.get();
  const threads = result.docs
    .map((doc) => doc.data())
    .sort((a, b) => (b.updatedAt?.toMillis?.() ?? 0) - (a.updatedAt?.toMillis?.() ?? 0));
  for (const thread of threads) {
    console.log(
      `#${thread.number ?? "?"}\t${thread.status}\t${thread.kind}\t${stamp(thread.updatedAt)}\t` +
      `${thread.title} — ${thread.lastMessagePreview}`
    );
  }
  console.log(`${threads.length} thread(s)`);
}

async function show(number: number): Promise<void> {
  const thread = await threadByNumber(number);
  const data = thread.data();
  console.log(`#${data.number} ${data.title}`);
  console.log(`status ${data.status} · ${data.kind} · ${data.locale} · App ${data.appVersion} (${data.build}) · ` +
    `${data.osVersion} · ${data.device}`);
  if (data.diagnosticReportId) console.log(`diagnostic log ${data.diagnosticReportId}`);
  console.log(`device ${JSON.stringify(data.deviceInfo ?? {})}`);
  console.log(`path ${thread.ref.path}\n`);
  const messages = await thread.ref.collection("messages").orderBy("createdAt").get();
  for (const message of messages.docs.map((doc) => doc.data())) {
    console.log(`[${message.author} · ${stamp(message.createdAt)}]`);
    console.log(message.text);
    for (const attachment of message.attachments ?? []) {
      console.log(`  ${attachment.kind}: gs://yuedu-readerr.firebasestorage.app/${attachment.path}`);
    }
    console.log();
  }
}

async function reply(number: number, text: string, status?: string): Promise<void> {
  const thread = await threadByNumber(number);
  const batch = db.batch();
  batch.set(thread.ref.collection("messages").doc(), {
    author: "developer",
    text,
    attachments: [],
    createdAt: FieldValue.serverTimestamp(),
  });
  batch.update(thread.ref, {
    ...(status !== undefined ? {status: parseStatus(status)} : {}),
    lastMessageAt: FieldValue.serverTimestamp(),
    lastMessagePreview: messagePreview(text),
    lastMessageAuthor: "developer",
    lastReplyAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();
  console.log(`replied to #${number}${status !== undefined ? `, status ${status}` : ""}`);
}

async function setStatus(number: number, status: string): Promise<void> {
  const thread = await threadByNumber(number);
  await thread.ref.update({status: parseStatus(status), updatedAt: FieldValue.serverTimestamp()});
  console.log(`#${number} is ${status}`);
}

async function main(): Promise<void> {
  const [command, ...rest] = process.argv.slice(2);
  switch (command) {
  case "list": return list(rest[0]);
  case "show": return show(Number(rest[0]));
  case "reply": {
    const statusFlag = rest.indexOf("--status");
    const status = statusFlag >= 0 ? rest[statusFlag + 1] : undefined;
    return reply(Number(rest[0]), rest[1] ?? "", status);
  }
  case "status": return setStatus(Number(rest[0]), rest[1]);
  default:
    console.log("usage: feedback.ts list|show|reply|status — see the header of tools/feedback.ts");
    process.exitCode = 2;
  }
}

main().catch((error) => {
  console.error(String(error));
  process.exitCode = 1;
});
