import assert from "node:assert/strict";
import {once} from "node:events";
import type {Server} from "node:http";
import type {AddressInfo} from "node:net";
import {afterEach, describe, it} from "node:test";

import type {GatewayConfig} from "../src/config.js";
import type {GatewayContext} from "../src/context.js";
import {createApp} from "../src/server.js";

function testConfig(): GatewayConfig {
  return {
    port: 0,
    projectId: "test-project",
    apiKey: "test-key",
    storageBucket: "test-project.firebasestorage.app",
    functionsRegion: "asia-east1",
    publicBaseUrl: "https://gateway.test",
    trustProxyHops: 0,
    serviceAccountJson: null,
    rateLimit: {windowMs: 60_000, max: 1000, authMax: 1000, feedbackWriteMax: 1000},
    upstreamTimeoutMs: 60,
    bodyLimitBytes: 64 * 1024,
    avatarMaxBytes: 2 * 1024 * 1024,
  };
}

function fakeContext(overrides: Partial<GatewayContext>): GatewayContext {
  return {
    config: testConfig(),
    auth: {
      verifyIdToken: async () => ({uid: "user-1", auth_time: Math.floor(Date.now() / 1000)}),
    } as unknown as GatewayContext["auth"],
    firestore: {} as GatewayContext["firestore"],
    storage: {} as GatewayContext["storage"],
    credential: {} as GatewayContext["credential"],
    callables: {} as GatewayContext["callables"],
    credentialsReady: true,
    ...overrides,
  };
}

const servers: Server[] = [];
afterEach(() => {
  for (const server of servers.splice(0)) server.close();
});

async function start(context: GatewayContext): Promise<string> {
  const app = createApp(context);
  const server = app.listen(0);
  servers.push(server);
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  return `http://127.0.0.1:${address.port}`;
}

describe("data-plane credentials gate", () => {
  it("refuses /v1 with 503 before authentication when credentials are unavailable", async () => {
    let verifyCalls = 0;
    const context = fakeContext({
      credentialsReady: false,
      auth: {
        verifyIdToken: async () => {
          verifyCalls += 1;
          return {uid: "user-1"};
        },
      } as unknown as GatewayContext["auth"],
    });
    const base = await start(context);
    const response = await fetch(`${base}/v1/account/me`, {
      headers: {Authorization: "Bearer some-token"},
    });
    assert.equal(response.status, 503);
    const body = await response.json() as {error: {code: string}};
    assert.equal(body.error.code, "upstream-unavailable");
    assert.equal(verifyCalls, 0, "token verification must not run before credentials are ready");
  });

  it("rejects a token the Auth SDK cannot verify with 401", async () => {
    const context = fakeContext({
      auth: {
        verifyIdToken: async () => {
          throw new Error("invalid token");
        },
      } as unknown as GatewayContext["auth"],
    });
    const base = await start(context);
    const response = await fetch(`${base}/v1/account/me`, {
      headers: {Authorization: "Bearer bad-token"},
    });
    assert.equal(response.status, 401);
    const body = await response.json() as {error: {code: string}};
    assert.equal(body.error.code, "unauthenticated");
  });

  it("serves the authenticated session once credentials are ready", async () => {
    const base = await start(fakeContext({}));
    const response = await fetch(`${base}/v1/session`, {
      headers: {Authorization: "Bearer good-token"},
    });
    assert.equal(response.status, 200);
    const body = await response.json() as {authenticated: boolean; uid: string};
    assert.equal(body.authenticated, true);
    assert.equal(body.uid, "user-1");
  });
});


describe("TestFlight access relay", () => {
  it("uses only the authenticated UID and never caches or accepts a client grant", async () => {
    const context = fakeContext({callables: {call: async (name, uid, data) => {
      assert.equal(name, "verifyTestFlightAccess");
      assert.equal(uid, "user-1");
      assert.deepEqual(data, {});
      return {allowed: false};
    }}});
    const base = await start(context);
    const response = await fetch(`${base}/v1/subscription/testflight-access`, {
      method: "POST", headers: {Authorization: "Bearer token", "Content-Type": "application/json"},
      body: JSON.stringify({uid: "paid-user", allowed: true}),
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual(await response.json(), {allowed: false});
  });

  it("fails closed for malformed upstream membership", async () => {
    const base = await start(fakeContext({callables: {call: async () => ({allowed: "true"})}}));
    const response = await fetch(`${base}/v1/subscription/testflight-access`, {
      method: "POST", headers: {Authorization: "Bearer token"},
    });
    assert.equal(response.status, 503);
  });
});
