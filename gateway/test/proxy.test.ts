import assert from "node:assert/strict";
import {once} from "node:events";
import type {Server} from "node:http";
import type {AddressInfo} from "node:net";
import {afterEach, describe, it} from "node:test";

import express from "express";

import {RateLimiter} from "../src/rateLimit.js";

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

interface IpBody {
  ip: string;
  ips: string[];
}

describe("proxy trust", () => {
  it("ignores a forged X-Forwarded-For when no proxy is trusted", async () => {
    const app = express();
    app.set("trust proxy", 0);
    app.get("/ip", (request, response) => {
      response.json({ip: request.ip, ips: request.ips});
    });
    const base = await start(app);
    const response = await fetch(`${base}/ip`, {
      headers: {"X-Forwarded-For": "1.2.3.4"},
    });
    const body = await response.json() as IpBody;
    assert.notEqual(body.ip, "1.2.3.4");
    assert.match(body.ip, /127\.0\.0\.1/);
    assert.deepEqual(body.ips, []);
  });

  it("uses only the rightmost entry with exactly one trusted hop", async () => {
    const app = express();
    app.set("trust proxy", 1);
    app.get("/ip", (request, response) => {
      response.json({ip: request.ip, ips: request.ips});
    });
    const base = await start(app);
    const response = await fetch(`${base}/ip`, {
      headers: {"X-Forwarded-For": "1.2.3.4, 203.0.113.9"},
    });
    const body = await response.json() as IpBody;
    // The proxy-set address wins; the client-stuffed leftmost entry is ignored.
    assert.equal(body.ip, "203.0.113.9");
    assert.deepEqual(body.ips, ["203.0.113.9"]);
  });

  it("a spoofed leftmost entry cannot bypass the rate limit", async () => {
    const limiter = new RateLimiter(60_000, 1);
    const app = express();
    app.set("trust proxy", 1);
    app.get("/limited", (request, response) => {
      const retryAfter = limiter.consume(`route|${request.ip}`);
      if (retryAfter !== null) {
        response.status(429).json({retryAfter});
        return;
      }
      response.json({ok: true, ip: request.ip});
    });
    const base = await start(app);

    const first = await fetch(`${base}/limited`, {
      headers: {"X-Forwarded-For": "9.9.9.9, 203.0.113.9"},
    });
    assert.equal(first.status, 200);

    // Same real client, different forged leftmost value: still the same bucket.
    const second = await fetch(`${base}/limited`, {
      headers: {"X-Forwarded-For": "8.8.8.8, 203.0.113.9"},
    });
    assert.equal(second.status, 429);

    // A genuinely different real client is a different bucket.
    const third = await fetch(`${base}/limited`, {
      headers: {"X-Forwarded-For": "9.9.9.9, 203.0.113.10"},
    });
    assert.equal(third.status, 200);
  });
});
