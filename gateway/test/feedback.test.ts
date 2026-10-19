import assert from "node:assert/strict";
import {once} from "node:events";
import type {Server} from "node:http";
import type {AddressInfo} from "node:net";
import {Readable, Writable} from "node:stream";
import {afterEach, describe, it} from "node:test";

import {FieldValue} from "firebase-admin/firestore";

import type {GatewayConfig} from "../src/config.js";
import type {GatewayContext} from "../src/context.js";
import {
  DIAGNOSTIC_LIMITS,
  FEEDBACK_LIMITS,
  declaredUploadLength,
  inboxKeyFromAuthorization,
  sanitizeDiagnosticReport,
  sanitizeNewThread,
  sanitizeReply,
  statusAfterReply,
  threadPayload,
  uploadTarget,
} from "../src/feedbackPolicy.js";
import {createApp} from "../src/server.js";

const INBOX = "A".repeat(42) + "b";
const OTHER_INBOX = "Z".repeat(43);
const THREAD = "0f8fad5b-d9cb-469f-a165-70867728950e";
const FILE = "7c9e6679-7425-40de-944b-e07fc1f90ae7.jpg";

function newThreadBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    threadId: THREAD,
    kind: "bug",
    title: "翻頁卡住",
    preview: "翻頁卡住 第二行",
    text: "翻頁卡住\n第二行",
    attachments: [],
    appVersion: "2.0.8",
    build: "2",
    osVersion: "iOS 26.1",
    device: "iPhone18,2",
    locale: "zh-Hans-CN",
    installId: "install-1",
    diagnosticReportId: "",
    deviceInfo: {model: "iPhone18,2", systemVersion: "26.1"},
    ...overrides,
  };
}

// MARK: - Policy

describe("feedback policy", () => {
  it("reads the inbox key only from an Inbox authorization", () => {
    assert.equal(inboxKeyFromAuthorization(`Inbox ${INBOX}`), INBOX);
    for (const header of [undefined, "", `Bearer ${INBOX}`, `Inbox ${INBOX}x`, "Inbox short", `Inbox ${INBOX} extra`]) {
      assert.throws(() => inboxKeyFromAuthorization(header), {code: "unauthenticated"});
    }
  });

  it("accepts a report within the thread create rule", () => {
    const report = sanitizeNewThread(newThreadBody(), INBOX);
    assert.equal(report.kind, "bug");
    assert.equal(report.text, "翻頁卡住\n第二行");
    assert.deepEqual(report.deviceInfo, {model: "iPhone18,2", systemVersion: "26.1"});
  });

  it("refuses what the thread create rule refuses", () => {
    const refusals: Array<Record<string, unknown>> = [
      {kind: "praise"},
      {threadId: "not-a-uuid"},
      {text: "   "},
      {title: "長".repeat(FEEDBACK_LIMITS.title + 1)},
      {preview: "x".repeat(FEEDBACK_LIMITS.preview + 1)},
      {text: "x".repeat(FEEDBACK_LIMITS.text + 1)},
      {diagnosticReportId: "x".repeat(FEEDBACK_LIMITS.diagnosticReportId + 1)},
      {deviceInfo: Object.fromEntries(Array.from({length: 21}, (_, index) => [`k${index}`, "v"]))},
      {deviceInfo: {model: 7}},
      {deviceInfo: {"bad key": "v"}},
      {appVersion: 2},
    ];
    for (const overrides of refusals) {
      assert.throws(() => sanitizeNewThread(newThreadBody(overrides), INBOX), {code: "invalid-argument"}, JSON.stringify(overrides));
    }
  });

  it("lets a message cite only attachments under its own inbox and thread", () => {
    const own = {path: `feedback/${INBOX}/${THREAD}/${FILE}`, width: 10, height: 20};
    assert.equal(sanitizeNewThread(newThreadBody({attachments: [own]}), INBOX).attachments[0]?.fileName, FILE);
    const foreign = [
      {path: `feedback/${OTHER_INBOX}/${THREAD}/${FILE}`},
      {path: `feedback/${INBOX}/7c9e6679-7425-40de-944b-e07fc1f90ae7/${FILE}`},
      {path: `avatars/${FILE}`},
    ];
    for (const attachment of foreign) {
      assert.throws(() => sanitizeNewThread(newThreadBody({attachments: [attachment]}), INBOX), {code: "permission-denied"});
    }
    assert.throws(
      () => sanitizeNewThread(newThreadBody({attachments: [{path: `feedback/${INBOX}/${THREAD}/../x.jpg`}]}), INBOX),
      {code: "invalid-argument"}
    );
    assert.throws(
      () => sanitizeNewThread(newThreadBody({attachments: Array.from({length: 6}, () => own)}), INBOX),
      {code: "invalid-argument"}
    );
    assert.throws(() => sanitizeNewThread(newThreadBody({attachments: [own, own]}), INBOX), {code: "invalid-argument"});
  });

  it("needs text or an attachment in a reply", () => {
    assert.throws(() => sanitizeReply({text: " ", attachments: []}, INBOX, THREAD), {code: "invalid-argument"});
    const reply = sanitizeReply(
      {text: "", preview: "〔附件〕", attachments: [{path: `feedback/${INBOX}/${THREAD}/${FILE}`}]},
      INBOX,
      THREAD
    );
    assert.equal(reply.attachments.length, 1);
  });

  it("moves a thread only from needsInfo to queued on a reply", () => {
    assert.equal(statusAfterReply("needsInfo"), "queued");
    for (const status of ["received", "queued", "processing", "done", undefined]) {
      assert.equal(statusAfterReply(status), null);
    }
  });

  it("takes images up to 15 MB and videos up to 50 MB, nothing else", () => {
    assert.equal(uploadTarget("image/jpeg", "jpg").maxBytes, 15 * 1024 * 1024);
    assert.equal(uploadTarget("video/quicktime", "mov").kind, "video");
    assert.equal(uploadTarget("video/quicktime", "mov").maxBytes, 50 * 1024 * 1024);
    assert.throws(() => uploadTarget("text/plain", "txt"), {code: "unsupported-media-type"});
    assert.throws(() => uploadTarget(undefined, "jpg"), {code: "unsupported-media-type"});
    assert.throws(() => uploadTarget("image/jpeg", "../x"), {code: "invalid-argument"});
    assert.equal(declaredUploadLength("100", 100), 100);
    assert.throws(() => declaredUploadLength("101", 100), {code: "payload-too-large"});
    assert.throws(() => declaredUploadLength(undefined, 100), {code: "invalid-argument"});
    assert.throws(() => declaredUploadLength("0", 100), {code: "invalid-argument"});
  });

  it("checks a diagnostic report the way the diagnosticReports rule does", () => {
    const valid = {
      reportId: "YD-ABCD-2345", payload: Buffer.from("log").toString("base64"), payloadEncoding: "deflate-utf8",
      payloadBytes: 3, keptEntries: 1, totalEntries: 1, note: "n", scale: "s",
    };
    assert.deepEqual(sanitizeDiagnosticReport(valid).payload, Buffer.from("log"));
    assert.throws(() => sanitizeDiagnosticReport({...valid, reportId: "YD-ABCD-0000"}), {code: "invalid-argument"});
    assert.throws(() => sanitizeDiagnosticReport({...valid, note: "x".repeat(DIAGNOSTIC_LIMITS.note + 1)}), {code: "invalid-argument"});
    assert.throws(
      () => sanitizeDiagnosticReport({...valid, payload: Buffer.alloc(DIAGNOSTIC_LIMITS.payloadBytes + 1).toString("base64")}),
      {code: "payload-too-large"}
    );
    assert.throws(() => sanitizeDiagnosticReport({...valid, payloadEncoding: "raw"}), {code: "invalid-argument"});
  });

  it("returns only the thread fields the app reads, dates as ISO strings", () => {
    const payload = threadPayload("t1", {
      kind: "bug", status: "queued", number: 3, installId: "secret-ish", deviceInfo: {model: "x"},
      createdAt: {toDate: () => new Date("2026-10-17T01:02:03.000Z")},
    });
    assert.equal(payload.createdAt, "2026-10-17T01:02:03.000Z");
    assert.equal(payload.updatedAt, null);
    assert.equal("installId" in payload, false);
    assert.equal("deviceInfo" in payload, false);
  });
});

// MARK: - Routes, against an in-memory Firestore and Storage

type Data = Record<string, unknown>;

class FakeFirestore {
  readonly documents = new Map<string, Data>();

  collection(path: string): FakeCollection {
    return new FakeCollection(this, path);
  }

  batch(): FakeWrites {
    return new FakeWrites(this);
  }

  async runTransaction(body: (transaction: FakeWrites & {get(ref: FakeDocument): Promise<FakeSnapshot>}) => Promise<void>): Promise<void> {
    const writes = new FakeWrites(this);
    await body(Object.assign(writes, {get: (ref: FakeDocument) => ref.get()}));
    await writes.commit();
  }

  async getAll(...refs: FakeDocument[]): Promise<FakeSnapshot[]> {
    return Promise.all(refs.map((ref) => ref.get()));
  }
}

class FakeCollection {
  constructor(private readonly store: FakeFirestore, readonly path: string) {}

  doc(id: string): FakeDocument {
    return new FakeDocument(this.store, `${this.path}/${id}`);
  }

  orderBy(): FakeCollection {
    return this;
  }

  async get(): Promise<{docs: FakeSnapshot[]}> {
    const depth = this.path.split("/").length + 1;
    const docs = [...this.store.documents.keys()]
      .filter((key) => key.startsWith(`${this.path}/`) && key.split("/").length === depth)
      .map((key) => new FakeSnapshot(this.store, key));
    return {docs};
  }
}

class FakeDocument {
  constructor(private readonly store: FakeFirestore, readonly path: string) {}

  get id(): string {
    return this.path.split("/").at(-1) ?? "";
  }

  collection(name: string): FakeCollection {
    return new FakeCollection(this.store, `${this.path}/${name}`);
  }

  async get(): Promise<FakeSnapshot> {
    return new FakeSnapshot(this.store, this.path);
  }

  async create(data: Data): Promise<void> {
    const writes = new FakeWrites(this.store);
    writes.create(this, data);
    await writes.commit();
  }

  async set(data: Data): Promise<void> {
    this.store.documents.set(this.path, resolve(data));
  }

  async update(data: Data): Promise<void> {
    const writes = new FakeWrites(this.store);
    writes.update(this, data);
    await writes.commit();
  }
}

class FakeSnapshot {
  constructor(private readonly store: FakeFirestore, private readonly path: string) {}

  get id(): string {
    return this.path.split("/").at(-1) ?? "";
  }

  get exists(): boolean {
    return this.store.documents.has(this.path);
  }

  get ref(): FakeDocument {
    return new FakeDocument(this.store, this.path);
  }

  data(): Data {
    return this.store.documents.get(this.path) ?? {};
  }

  get(field: string): unknown {
    return this.data()[field];
  }
}

class FakeWrites {
  private readonly operations: Array<() => void> = [];

  constructor(private readonly store: FakeFirestore) {}

  create(ref: FakeDocument, data: Data): void {
    this.operations.push(() => {
      if (this.store.documents.has(ref.path)) throw Object.assign(new Error("exists"), {code: 6});
      this.store.documents.set(ref.path, resolve(data));
    });
  }

  update(ref: FakeDocument, data: Data): void {
    this.operations.push(() => {
      const existing = this.store.documents.get(ref.path);
      if (existing === undefined) throw Object.assign(new Error("missing"), {code: 5});
      this.store.documents.set(ref.path, {...existing, ...resolve(data)});
    });
  }

  async commit(): Promise<void> {
    // All or nothing, as a batch is.
    const before = new Map(this.store.documents);
    try {
      for (const operation of this.operations) operation();
    } catch (error) {
      this.store.documents.clear();
      for (const [key, value] of before) this.store.documents.set(key, value);
      throw error;
    }
  }
}

function resolve(data: Data): Data {
  return Object.fromEntries(Object.entries(data).map(([key, value]) => [key, value instanceof FieldValue ? new Date() : value]));
}

class FakeStorage {
  readonly objects = new Map<string, {bytes: Buffer; contentType: string}>();

  bucket(): {file(path: string): unknown} {
    return {
      file: (path: string) => ({
        getMetadata: async () => {
          const object = this.objects.get(path);
          if (object === undefined) throw Object.assign(new Error("No such object"), {code: 404});
          return [{contentType: object.contentType, size: String(object.bytes.length)}];
        },
        createReadStream: () => Readable.from([this.objects.get(path)?.bytes ?? Buffer.alloc(0)]),
        createWriteStream: (options: {contentType: string; preconditionOpts?: {ifGenerationMatch?: number}}) => {
          const chunks: Buffer[] = [];
          return new Writable({
            write: (chunk: Buffer, _encoding, callback) => {
              chunks.push(chunk);
              callback();
            },
            final: (callback) => {
              if (options.preconditionOpts?.ifGenerationMatch === 0 && this.objects.has(path)) {
                callback(Object.assign(new Error("precondition"), {code: 412}));
                return;
              }
              this.objects.set(path, {bytes: Buffer.concat(chunks), contentType: options.contentType});
              callback();
            },
          });
        },
      }),
    };
  }
}

function testConfig(feedbackWriteMax = 1000): GatewayConfig {
  return {
    port: 0,
    projectId: "test-project",
    apiKey: "test-key",
    storageBucket: "test-project.firebasestorage.app",
    functionsRegion: "asia-east1",
    publicBaseUrl: "https://gateway.test",
    trustProxyHops: 0,
    serviceAccountJson: null,
    rateLimit: {windowMs: 60_000, max: 1000, authMax: 1000, feedbackWriteMax},
    upstreamTimeoutMs: 1000,
    bodyLimitBytes: 64 * 1024,
    avatarMaxBytes: 2 * 1024 * 1024,
  };
}

const servers: Server[] = [];
afterEach(() => {
  for (const server of servers.splice(0)) server.close();
});

async function start(feedbackWriteMax?: number): Promise<{base: string; firestore: FakeFirestore; storage: FakeStorage}> {
  const firestore = new FakeFirestore();
  const storage = new FakeStorage();
  const context: GatewayContext = {
    config: testConfig(feedbackWriteMax),
    auth: {} as GatewayContext["auth"],
    firestore: firestore as unknown as GatewayContext["firestore"],
    storage: storage as unknown as GatewayContext["storage"],
    credential: {} as GatewayContext["credential"],
    callables: {} as GatewayContext["callables"],
    credentialsReady: true,
  };
  const server = createApp(context).listen(0);
  servers.push(server);
  await once(server, "listening");
  return {base: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, firestore, storage};
}

function inboxHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return {Authorization: `Inbox ${INBOX}`, ...extra};
}

async function postJSON(base: string, path: string, body: unknown, headers = inboxHeaders()): Promise<Response> {
  return fetch(`${base}${path}`, {
    method: "POST",
    headers: {"Content-Type": "application/json", ...headers},
    body: JSON.stringify(body),
  });
}

const threadPath = `feedbackInboxes/${INBOX}/threads/${THREAD}`;

describe("feedback routes", () => {
  it("refuses a request that names no inbox", async () => {
    const {base} = await start();
    const response = await fetch(`${base}/v1/feedback/threads`);
    assert.equal(response.status, 401);
  });

  it("files a report with its first message and an uploaded attachment", async () => {
    const {base, firestore, storage} = await start();
    const upload = await fetch(`${base}/v1/feedback/threads/${THREAD}/attachments?extension=jpg`, {
      method: "PUT",
      headers: inboxHeaders({"Content-Type": "image/jpeg"}),
      body: Buffer.from([0xff, 0xd8, 0xff, 0x00]),
    });
    assert.equal(upload.status, 201);
    const uploaded = (await upload.json()) as {path: string; bytes: number};
    assert.match(uploaded.path, new RegExp(`^feedback/${INBOX}/${THREAD}/[0-9a-f-]{36}\\.jpg$`));
    assert.equal(uploaded.bytes, 4);
    assert.equal(storage.objects.get(uploaded.path)?.contentType, "image/jpeg");

    const created = await postJSON(base, "/v1/feedback/threads", newThreadBody({
      attachments: [{path: uploaded.path, kind: "video", contentType: "video/mp4", bytes: 999, width: 3, height: 4}],
    }));
    assert.equal(created.status, 201);

    const thread = firestore.documents.get(threadPath);
    assert.equal(thread?.status, "received");
    assert.equal(thread?.lastMessageAuthor, "user");
    assert.ok(thread?.createdAt instanceof Date);
    const messages = [...firestore.documents.entries()].filter(([key]) => key.startsWith(`${threadPath}/messages/`));
    assert.equal(messages.length, 1);
    const message = messages[0]?.[1];
    assert.equal(message?.author, "user");
    // Kind, type and size come from Storage, not from the client's descriptor.
    assert.deepEqual(message?.attachments, [
      {path: uploaded.path, kind: "image", contentType: "image/jpeg", bytes: 4, width: 3, height: 4},
    ]);
  });

  it("refuses a report that reuses a thread id or cites a missing upload", async () => {
    const {base, firestore} = await start();
    assert.equal((await postJSON(base, "/v1/feedback/threads", newThreadBody())).status, 201);
    assert.equal((await postJSON(base, "/v1/feedback/threads", newThreadBody())).status, 409);
    const missing = await postJSON(base, "/v1/feedback/threads", newThreadBody({
      threadId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
      attachments: [{path: `feedback/${INBOX}/7c9e6679-7425-40de-944b-e07fc1f90ae7/${FILE}`}],
    }));
    assert.equal(missing.status, 400);
    assert.equal(firestore.documents.has(`feedbackInboxes/${INBOX}/threads/7c9e6679-7425-40de-944b-e07fc1f90ae7`), false);
  });

  it("puts a needsInfo thread back in the queue on a reply, and 404s an unknown thread", async () => {
    const {base, firestore} = await start();
    await postJSON(base, "/v1/feedback/threads", newThreadBody());
    firestore.documents.set(threadPath, {...firestore.documents.get(threadPath), status: "needsInfo"});
    const reply = await postJSON(base, `/v1/feedback/threads/${THREAD}/messages`, {text: "補充", preview: "補充"});
    assert.equal(reply.status, 201);
    assert.equal(firestore.documents.get(threadPath)?.status, "queued");
    assert.equal(firestore.documents.get(threadPath)?.lastMessagePreview, "補充");

    const again = await postJSON(base, `/v1/feedback/threads/${THREAD}/messages`, {text: "再補充", preview: "再補充"});
    assert.equal(again.status, 201);
    assert.equal(firestore.documents.get(threadPath)?.status, "queued");

    const unknown = await postJSON(base, "/v1/feedback/threads/7c9e6679-7425-40de-944b-e07fc1f90ae7/messages", {text: "x"});
    assert.equal(unknown.status, 404);
  });

  it("lists an inbox's threads and messages, not another inbox's", async () => {
    const {base} = await start();
    await postJSON(base, "/v1/feedback/threads", newThreadBody());
    const list = (await (await fetch(`${base}/v1/feedback/threads`, {headers: inboxHeaders()})).json()) as {
      threads: Array<Record<string, unknown>>;
    };
    assert.equal(list.threads.length, 1);
    assert.equal(list.threads[0]?.id, THREAD);
    assert.match(String(list.threads[0]?.createdAt), /^\d{4}-\d{2}-\d{2}T/);
    assert.equal("installId" in (list.threads[0] ?? {}), false);

    const messages = (await (await fetch(`${base}/v1/feedback/threads/${THREAD}/messages`, {headers: inboxHeaders()})).json()) as {
      messages: Array<Record<string, unknown>>;
    };
    assert.equal(messages.messages[0]?.text, "翻頁卡住\n第二行");

    const other = (await (await fetch(`${base}/v1/feedback/threads`, {headers: {Authorization: `Inbox ${OTHER_INBOX}`}})).json()) as {
      threads: unknown[];
    };
    assert.equal(other.threads.length, 0);
  });

  it("marks threads read and solved", async () => {
    const {base, firestore} = await start();
    await postJSON(base, "/v1/feedback/threads", newThreadBody());
    const before = firestore.documents.get(threadPath)?.userLastReadAt;
    const read = await postJSON(base, "/v1/feedback/read", {threadIds: [THREAD, "7c9e6679-7425-40de-944b-e07fc1f90ae7"]});
    assert.deepEqual(await read.json(), {read: [THREAD]});
    assert.notEqual(firestore.documents.get(threadPath)?.userLastReadAt, before);
    assert.equal((await postJSON(base, `/v1/feedback/threads/${THREAD}/resolve`, {})).status, 200);
    assert.equal(firestore.documents.get(threadPath)?.status, "done");
    // The push trigger tells the user's own resolve apart by this.
    assert.ok(firestore.documents.get(threadPath)?.userResolvedAt instanceof Date);
  });

  it("registers a device for push under its install id, replacing its old token", async () => {
    const {base, firestore} = await start();
    const device = "0f8fad5b-d9cb-469f-a165-70867728950e";
    const put = (body: unknown, id = device) => fetch(`${base}/v1/feedback/push-devices/${id}`, {
      method: "PUT",
      headers: inboxHeaders({"Content-Type": "application/json"}),
      body: JSON.stringify(body),
    });
    assert.equal((await put({token: "ab".repeat(32), environment: "development"})).status, 204);
    assert.equal((await put({token: "cd".repeat(32), environment: "production"})).status, 204);
    const stored = firestore.documents.get(`feedbackInboxes/${INBOX}/pushDevices/${device}`);
    assert.equal(stored?.token, "cd".repeat(32));
    assert.equal(stored?.environment, "production");

    assert.equal((await put({token: "not-hex", environment: "production"})).status, 400);
    assert.equal((await put({token: "ab".repeat(32), environment: "staging"})).status, 400);
    assert.equal((await put({token: "ab".repeat(32), environment: "production"}, "UPPER-CASE")).status, 400);
    const anonymous = await fetch(`${base}/v1/feedback/push-devices/${device}`, {
      method: "PUT", headers: {"Content-Type": "application/json"}, body: "{}",
    });
    assert.equal(anonymous.status, 401);
  });

  it("refuses an oversized upload before storing anything", async () => {
    const {base, storage} = await start();
    const response = await fetch(`${base}/v1/feedback/threads/${THREAD}/attachments?extension=jpg`, {
      method: "PUT",
      headers: inboxHeaders({"Content-Type": "image/jpeg", "Content-Length": String(16 * 1024 * 1024)}),
      body: Buffer.alloc(16),
    }).catch(() => null);
    if (response !== null) assert.equal(response.status, 413);
    assert.equal(storage.objects.size, 0);
  });

  it("serves an attachment by thread and file name only", async () => {
    const {base, storage} = await start();
    storage.objects.set(`feedback/${INBOX}/${THREAD}/${FILE}`, {bytes: Buffer.from("img"), contentType: "image/jpeg"});
    const response = await fetch(`${base}/v1/feedback/threads/${THREAD}/attachments/${FILE}`, {headers: inboxHeaders()});
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/jpeg");
    assert.equal(Buffer.from(await response.arrayBuffer()).toString(), "img");
    const other = await fetch(`${base}/v1/feedback/threads/${THREAD}/attachments/${FILE}`, {
      headers: {Authorization: `Inbox ${OTHER_INBOX}`},
    });
    assert.equal(other.status, 404);
  });

  it("stores a diagnostic log larger than the general body limit, as bytes", async () => {
    const {base, firestore} = await start();
    const payload = Buffer.alloc(800_000, 7);
    const response = await postJSON(base, "/v1/diagnostics/reports", {
      reportId: "YD-ABCD-2345", payload: payload.toString("base64"), payloadEncoding: "deflate-utf8",
      payloadBytes: 1_600_000, keptEntries: 10, totalEntries: 20, note: "bug feedback", scale: "",
    }, {});
    assert.equal(response.status, 201);
    const stored = firestore.documents.get("diagnosticReports/YD-ABCD-2345");
    assert.ok(Buffer.isBuffer(stored?.payload));
    assert.equal((stored?.payload as Buffer).length, 800_000);
    const duplicate = await postJSON(base, "/v1/diagnostics/reports", {
      reportId: "YD-ABCD-2345", payload: "bG9n", payloadEncoding: "deflate-utf8",
      payloadBytes: 3, keptEntries: 1, totalEntries: 1,
    }, {});
    assert.equal(duplicate.status, 409);
  });

  it("limits writes per inbox, and never logs the inbox key", async () => {
    const lines: string[] = [];
    const write = process.stdout.write.bind(process.stdout);
    process.stdout.write = ((chunk: string | Uint8Array) => {
      lines.push(String(chunk));
      return true;
    }) as typeof process.stdout.write;
    try {
      const {base} = await start(2);
      const statuses: number[] = [];
      for (const threadId of [THREAD, "7c9e6679-7425-40de-944b-e07fc1f90ae7", "16fd2706-8baf-433b-82eb-8c7fada847da"]) {
        statuses.push((await postJSON(base, "/v1/feedback/threads", newThreadBody({threadId}))).status);
      }
      assert.deepEqual(statuses, [201, 201, 429]);
      await fetch(`${base}/v1/feedback/threads/${THREAD}/messages`, {headers: inboxHeaders()});
    } finally {
      process.stdout.write = write;
    }
    assert.ok(lines.some((line) => line.includes("/v1/feedback/threads")));
    assert.equal(lines.some((line) => line.includes(INBOX)), false);
  });
});
