import assert from "node:assert/strict";
import {once} from "node:events";
import type {Server} from "node:http";
import type {AddressInfo} from "node:net";
import {afterEach, beforeEach, describe, it} from "node:test";

import type {GatewayConfig} from "../src/config.js";
import type {GatewayContext} from "../src/context.js";
import {runAccountDeletion} from "../src/deletion.js";
import {ApiError} from "../src/errors.js";
import {linkEmailPassword, revokeTokenURL} from "../src/identityToolkit.js";
import {unverifiedTokenSubject, verifyReauthentication} from "../src/reauth.js";
import {createApp} from "../src/server.js";

function testConfig(): GatewayConfig {
  return {
    port: 0,
    projectId: "test-project",
    apiKey: "test-key",
    storageBucket: "test-project.firebasestorage.app",
    functionsRegion: "asia-east1",
    iosBundleId: "com.example.test",
    publicBaseUrl: "https://gateway.test",
    trustProxyHops: 0,
    serviceAccountJson: null,
    rateLimit: {windowMs: 60_000, max: 1000, authMax: 1000, feedbackWriteMax: 1000},
    upstreamTimeoutMs: 1000,
    bodyLimitBytes: 64 * 1024,
    avatarMaxBytes: 2 * 1024 * 1024,
  };
}

/** A provider ID token is only read for `sub` before Firebase verifies it. */
function fakeIdToken(claims: Record<string, unknown>): string {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${encode({alg: "RS256"})}.${encode(claims)}.signature`;
}

function userRecord(providerData: Array<{providerId: string; uid: string}>) {
  return {
    uid: "uid-1",
    email: "reader@example.com",
    displayName: "Reader",
    photoURL: undefined,
    emailVerified: false,
    disabled: false,
    providerData,
  };
}

// Identity Toolkit is reached through global fetch. Requests to it are recorded
// and answered here; anything else (the test's own calls to the local app) is
// passed through.
interface UpstreamCall {
  path: string;
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

const realFetch = globalThis.fetch;
let upstream: UpstreamCall[] = [];
let events: string[] = [];
let answer: (path: string) => {status: number; body: unknown} = () => ({status: 500, body: {}});

beforeEach(() => {
  upstream = [];
  events = [];
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (!url.startsWith("https://identitytoolkit.googleapis.com/")) {
      return realFetch(input, init);
    }
    const path = new URL(url).pathname;
    events.push(`upstream:${path}`);
    upstream.push({
      path,
      url,
      headers: {...(init?.headers as Record<string, string>)},
      body: JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>,
    });
    const {status, body} = answer(path);
    return new Response(typeof body === "string" ? body : JSON.stringify(body), {status});
  }) as typeof fetch;
});

const servers: Server[] = [];
afterEach(() => {
  globalThis.fetch = realFetch;
  for (const server of servers.splice(0)) server.close();
});

function deletionContext(jobWrites: Array<Record<string, unknown>>): GatewayContext {
  const emptyCollection = {limit: () => ({get: async () => ({empty: true, size: 0, docs: []})})};
  const userDocument = {
    collection: () => emptyCollection,
    delete: async () => {
      events.push("users.delete");
    },
  };
  const jobDocument = {
    set: async (data: Record<string, unknown>) => {
      jobWrites.push(data);
    },
  };
  return {
    config: testConfig(),
    auth: {
      deleteUser: async () => {
        events.push("auth.deleteUser");
      },
    } as unknown as GatewayContext["auth"],
    firestore: {
      collection: (name: string) => ({doc: () => (name === "accountDeletionJobs" ? jobDocument : userDocument)}),
    } as unknown as GatewayContext["firestore"],
    storage: {
      bucket: () => ({
        file: () => ({
          delete: async () => {
            events.push("avatar.delete");
          },
        }),
      }),
    } as unknown as GatewayContext["storage"],
    credential: {} as GatewayContext["credential"],
    callables: {
      call: async (name: string) => {
        events.push(`callable:${name}`);
        return {};
      },
    } as unknown as GatewayContext["callables"],
    credentialsReady: true,
  };
}

describe("Apple token revocation", () => {
  it("is addressed to Identity Platform v2, where the method exists", () => {
    assert.equal(
      revokeTokenURL("a b/c"),
      "https://identitytoolkit.googleapis.com/v2/accounts:revokeToken?key=a%20b%2Fc"
    );
  });
});

describe("account deletion", () => {
  it("a failed Apple revocation stops before anything is deleted", async () => {
    answer = () => ({status: 404, body: "<!DOCTYPE html><title>Error 404 (Not Found)!!1</title>"});
    const jobWrites: Array<Record<string, unknown>> = [];

    await assert.rejects(
      runAccountDeletion(deletionContext(jobWrites), "uid1", "apple-code", "id-token"),
      (error: unknown) => error instanceof ApiError && error.code === "apple-revoke-failed"
    );

    assert.deepEqual(events, ["upstream:/v2/accounts:revokeToken"]);
    const failure = jobWrites.at(-1);
    assert.deepEqual(failure?.stages, {appleRevocation: "failed"});
    assert.match(String((failure?.lastError as {message?: unknown}).message), /\[404\]/);
    for (const write of jobWrites) {
      assert.ok(Object.keys(write).every((key) => !key.includes(".")), "no literal dotted field names");
    }
  });

  it("revokes first, sent like the iOS SDK, and deletes the Auth user last", async () => {
    answer = () => ({status: 200, body: {}});
    const jobWrites: Array<Record<string, unknown>> = [];

    const job = await runAccountDeletion(deletionContext(jobWrites), "uid1", "apple-code", "id-token");

    assert.equal(job.status, "completed");
    assert.deepEqual(events, [
      "upstream:/v2/accounts:revokeToken",
      "callable:deleteSubscriptionAccountData",
      "users.delete",
      "avatar.delete",
      "auth.deleteUser",
    ]);
    assert.equal(upstream[0]?.url, revokeTokenURL("test-key"));
    assert.equal(upstream[0]?.headers["X-Ios-Bundle-Identifier"], "com.example.test");
    assert.deepEqual(upstream[0]?.body, {
      providerId: "apple.com",
      tokenType: "3",
      token: "apple-code",
      idToken: "id-token",
    });
  });

  it("an account without an Apple code skips revocation", async () => {
    const jobWrites: Array<Record<string, unknown>> = [];
    await runAccountDeletion(deletionContext(jobWrites), "uid1", null, "id-token");
    assert.equal(upstream.length, 0);
    assert.equal(events.at(-1), "auth.deleteUser");
  });
});

describe("email linking", () => {
  it("links through accounts:signUp with the caller's token and returns the new session", async () => {
    answer = () => ({
      status: 200,
      body: {idToken: "new-id", refreshToken: "new-refresh", expiresIn: "3600", localId: "uid-1"},
    });

    const session = await linkEmailPassword(
      {apiKey: "test-key", upstreamTimeoutMs: 1000},
      "old-id",
      "reader@example.com",
      "secret1"
    );

    assert.equal(upstream[0]?.path, "/v1/accounts:signUp");
    assert.deepEqual(upstream[0]?.body, {
      idToken: "old-id",
      email: "reader@example.com",
      password: "secret1",
      returnSecureToken: true,
    });
    assert.equal(session.refreshToken, "new-refresh");
    assert.equal(session.localId, "uid-1");
  });

  it("the link route hands the client the session that replaces its revoked one", async () => {
    answer = () => ({
      status: 200,
      body: {idToken: "new-id", refreshToken: "new-refresh", expiresIn: "3600", localId: "uid-1"},
    });
    const context = deletionContext([]);
    context.auth = {
      verifyIdToken: async () => ({uid: "uid-1", auth_time: Math.floor(Date.now() / 1000)}),
      getUser: async () => userRecord([{providerId: "apple.com", uid: "apple-sub"}]),
    } as unknown as GatewayContext["auth"];
    const app = createApp(context);
    const server = app.listen(0);
    servers.push(server);
    await once(server, "listening");
    const {port} = server.address() as AddressInfo;

    const response = await realFetch(`http://127.0.0.1:${port}/v1/auth/link/email`, {
      method: "POST",
      headers: {"Content-Type": "application/json", Authorization: "Bearer old-id"},
      body: JSON.stringify({email: "reader@example.com", password: "secret1"}),
    });

    assert.equal(response.status, 200);
    const payload = (await response.json()) as {refreshToken?: string; user?: {uid?: string}};
    assert.equal(payload.refreshToken, "new-refresh");
    assert.equal(payload.user?.uid, "uid-1");
  });
});

describe("re-authentication", () => {
  it("reads the subject of a provider token without trusting it", () => {
    assert.equal(unverifiedTokenSubject(fakeIdToken({sub: "apple-sub"})), "apple-sub");
    assert.equal(unverifiedTokenSubject("not-a-jwt"), null);
    assert.equal(unverifiedTokenSubject(fakeIdToken({aud: "x"})), null);
  });

  it("refuses a Google account other than the linked one before Firebase can create an account for it", async () => {
    const context = deletionContext([]);
    context.auth = {
      getUser: async () => userRecord([{providerId: "google.com", uid: "google-linked"}]),
    } as unknown as GatewayContext["auth"];

    await assert.rejects(
      verifyReauthentication(context, "uid-1", {provider: "google", idToken: fakeIdToken({sub: "google-other"})}),
      (error: unknown) => error instanceof ApiError && error.code === "wrong-account"
    );
    assert.equal(upstream.length, 0);
  });

  it("re-verifies the linked Apple account and passes its authorization code on", async () => {
    answer = () => ({
      status: 200,
      body: {idToken: "fresh-id", refreshToken: "fresh-refresh", expiresIn: "3600", localId: "uid-1"},
    });
    const context = deletionContext([]);
    context.auth = {
      getUser: async () => userRecord([{providerId: "apple.com", uid: "apple-sub"}]),
    } as unknown as GatewayContext["auth"];

    const verified = await verifyReauthentication(context, "uid-1", {
      provider: "apple",
      idToken: fakeIdToken({sub: "apple-sub"}),
      rawNonce: "nonce",
      appleAuthorizationCode: "apple-code",
    });

    assert.equal(upstream[0]?.path, "/v1/accounts:signInWithIdp");
    assert.equal(verified.session.idToken, "fresh-id");
    assert.equal(verified.appleAuthorizationCode, "apple-code");
  });
});
