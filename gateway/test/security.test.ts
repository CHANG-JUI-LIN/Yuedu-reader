import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {callableError} from "../src/callableProxy.js";
import {mapBodyParserError, mapIdentityToolkitError} from "../src/errors.js";
import {RateLimiter} from "../src/rateLimit.js";

describe("mapIdentityToolkitError", () => {
  it("maps wrong credentials without revealing account existence", () => {
    assert.equal(mapIdentityToolkitError(400, "EMAIL_NOT_FOUND").code, "invalid-credentials");
    assert.equal(mapIdentityToolkitError(400, "INVALID_PASSWORD").code, "invalid-credentials");
    assert.equal(mapIdentityToolkitError(400, "INVALID_LOGIN_CREDENTIALS").code, "invalid-credentials");
  });

  it("maps disabled and revoked accounts", () => {
    assert.equal(mapIdentityToolkitError(400, "USER_DISABLED").code, "user-disabled");
    assert.equal(mapIdentityToolkitError(400, "TOKEN_EXPIRED").code, "unauthenticated");
    assert.equal(mapIdentityToolkitError(400, "INVALID_REFRESH_TOKEN").code, "unauthenticated");
  });

  it("maps registration conflicts", () => {
    assert.equal(mapIdentityToolkitError(400, "EMAIL_EXISTS").code, "email-exists");
    assert.equal(
      mapIdentityToolkitError(400, "FEDERATED_USER_ID_ALREADY_LINKED").code,
      "credential-already-in-use"
    );
  });

  it("maps upstream outages to a retryable code", () => {
    assert.equal(mapIdentityToolkitError(503, "backend down").code, "upstream-unavailable");
    assert.equal(mapIdentityToolkitError(429, "quota").code, "rate-limited");
  });
});

describe("callableError", () => {
  it("keeps the gRPC code so the client can match existing callable handling", () => {
    const error = callableError(
      {error: {status: "ALREADY_EXISTS", message: "one slot"}},
      409
    );
    assert.equal(error.code, "conflict");
    assert.deepEqual(error.details, {grpcStatus: "ALREADY_EXISTS", grpcCode: 6});
  });

  it("maps permission denied and failed precondition", () => {
    assert.equal(
      callableError({error: {status: "PERMISSION_DENIED", message: "no"}}, 403).code,
      "permission-denied"
    );
    assert.equal(
      callableError({error: {status: "FAILED_PRECONDITION", message: "bad"}}, 400).code,
      "conflict"
    );
  });

  it("maps unavailable upstreams", () => {
    assert.equal(
      callableError({error: {status: "UNAVAILABLE", message: "down"}}, 503).code,
      "upstream-unavailable"
    );
  });
});

describe("mapBodyParserError", () => {
  it("maps oversized bodies to the structured payload-too-large code", () => {
    const mapped = mapBodyParserError(Object.assign(new Error("too large"), {type: "entity.too.large"}));
    assert.equal(mapped?.code, "payload-too-large");
    assert.equal(mapped?.status, 413);
  });

  it("leaves unrelated errors alone", () => {
    assert.equal(mapBodyParserError(new SyntaxError("bad json")), null);
    assert.equal(mapBodyParserError(null), null);
  });
});

describe("RateLimiter", () => {
  it("allows up to the limit then reports a retry window", () => {
    const limiter = new RateLimiter(60_000, 2);
    const now = 1_000;
    assert.equal(limiter.consume("ip", now), null);
    assert.equal(limiter.consume("ip", now), null);
    assert.equal(limiter.consume("ip", now), 60);
  });

  it("resets after the window and prunes stale buckets", () => {
    const limiter = new RateLimiter(1_000, 1);
    assert.equal(limiter.consume("ip", 1_000), null);
    assert.equal(limiter.consume("ip", 2_100), null);
    limiter.prune(10_000);
    assert.equal(limiter.consume("ip", 10_000), null);
  });

  it("keys are independent", () => {
    const limiter = new RateLimiter(1_000, 1);
    assert.equal(limiter.consume("a", 0), null);
    assert.equal(limiter.consume("b", 0), null);
    assert.equal(limiter.consume("a", 0), 1);
  });
});
