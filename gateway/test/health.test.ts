import assert from "node:assert/strict";
import {once} from "node:events";
import type {Server} from "node:http";
import type {AddressInfo} from "node:net";
import {afterEach, describe, it} from "node:test";

import express from "express";

import type {GatewayConfig} from "../src/config.js";
import type {GatewayContext} from "../src/context.js";
import {healthRouter} from "../src/routes/health.js";

function testConfig(): GatewayConfig {
  return {
    port: 0,
    projectId: "test-project",
    apiKey: "test-key",
    storageBucket: "test-project.firebasestorage.app",
    functionsRegion: "asia-east1",
    publicBaseUrl: "https://gateway.test",
    trustProxyHops: 1,
    serviceAccountJson: null,
    rateLimit: {windowMs: 60_000, max: 100, authMax: 10},
    upstreamTimeoutMs: 60,
    bodyLimitBytes: 64 * 1024,
    avatarMaxBytes: 2 * 1024 * 1024,
  };
}

function fakeContext(overrides: Partial<GatewayContext>): GatewayContext {
  return {
    config: testConfig(),
    auth: {} as GatewayContext["auth"],
    firestore: {
      listCollections: async () => [],
    } as unknown as GatewayContext["firestore"],
    storage: {
      bucket: () => ({exists: async () => [true]}),
    } as unknown as GatewayContext["storage"],
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

async function start(app: express.Express): Promise<string> {
  const server = app.listen(0);
  servers.push(server);
  await once(server, "listening");
  const address = server.address() as AddressInfo;
  return `http://127.0.0.1:${address.port}`;
}

function trackUnhandledRejections(): {seen: unknown[]; stop: () => void} {
  const seen: unknown[] = [];
  const handler = (reason: unknown): void => {
    seen.push(reason);
  };
  process.on("unhandledRejection", handler);
  return {
    seen,
    stop: () => process.off("unhandledRejection", handler),
  };
}

async function waitForRejectionWindow(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 120));
}

describe("readiness", () => {
  it("reports credentials-unavailable without touching Firestore", async () => {
    let called = false;
    const context = fakeContext({
      credentialsReady: false,
      firestore: {
        listCollections: async () => {
          called = true;
          return [];
        },
      } as unknown as GatewayContext["firestore"],
    });
    const app = express();
    app.use(healthRouter(context));
    const base = await start(app);
    const response = await fetch(`${base}/readyz`);
    assert.equal(response.status, 503);
    const body = await response.json() as {checks: Record<string, string>};
    assert.equal(body.checks.credentials, "unavailable");
    assert.equal(called, false, "Firestore must not be called while credentials are unavailable");
  });

  it("survives a credential error without an unhandled rejection", async () => {
    const tracker = trackUnhandledRejections();
    const context = fakeContext({
      firestore: {
        listCollections: () =>
          Promise.reject(
            new Error("Could not load the default credentials.")
          ),
      } as unknown as GatewayContext["firestore"],
      storage: {
        bucket: () => ({exists: () => Promise.reject(new Error("no credentials"))}),
      } as unknown as GatewayContext["storage"],
    });
    const app = express();
    app.use(healthRouter(context));
    const base = await start(app);
    const response = await fetch(`${base}/readyz`);
    assert.equal(response.status, 503);
    await waitForRejectionWindow();
    tracker.stop();
    assert.deepEqual(tracker.seen, []);
  });

  it("survives an upstream timeout without an unhandled rejection", async () => {
    const tracker = trackUnhandledRejections();
    const context = fakeContext({
      firestore: {
        listCollections: () => new Promise(() => {}),
      } as unknown as GatewayContext["firestore"],
      storage: {
        bucket: () => ({exists: () => new Promise(() => {})}),
      } as unknown as GatewayContext["storage"],
    });
    const app = express();
    app.use(healthRouter(context));
    const base = await start(app);
    const response = await fetch(`${base}/readyz`);
    assert.equal(response.status, 503);
    await waitForRejectionWindow();
    tracker.stop();
    assert.deepEqual(tracker.seen, []);
  });

  it("reports ready when both upstreams answer", async () => {
    const context = fakeContext({});
    const app = express();
    app.use(healthRouter(context));
    const base = await start(app);
    const response = await fetch(`${base}/readyz`);
    assert.equal(response.status, 200);
    const body = await response.json() as {status: string; checks: Record<string, string>};
    assert.equal(body.status, "ready");
    assert.equal(body.checks.firestore, "ok");
    assert.equal(body.checks.storage, "ok");
  });
});
