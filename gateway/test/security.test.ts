import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {callableError} from "../src/callableProxy.js";
import {accountUserPayload} from "../src/auth.js";
import {extractUpstreamCode, mapBodyParserError, mapIdentityToolkitError} from "../src/errors.js";
import {secureTokenURL} from "../src/identityToolkit.js";
import {RateLimiter} from "../src/rateLimit.js";

describe("secureTokenURL", () => {
  it("always carries the API key, which Token Service requires", () => {
    assert.equal(
      secureTokenURL("AIza-test"),
      "https://securetoken.googleapis.com/v1/token?key=AIza-test"
    );
    assert.equal(
      secureTokenURL("a b/c"),
      "https://securetoken.googleapis.com/v1/token?key=a%20b%2Fc"
    );
  });
});

describe("accountUserPayload", () => {
  it("normalizes null optional fields to empty strings for the Swift model", () => {
    const record = {
      uid: "u1",
      email: null,
      displayName: null,
      photoURL: null,
      emailVerified: false,
      disabled: false,
      providerData: [{providerId: "password"}],
    } as unknown as Parameters<typeof accountUserPayload>[0];
    const payload = accountUserPayload(record);
    assert.equal(payload.email, "");
    assert.equal(payload.displayName, "");
    assert.equal(payload.photoURL, null);
    assert.deepEqual(payload.providerIds, ["password"]);
  });
});

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

  it("classifies API key and provider configuration problems as permission, not bad input", () => {
    const blocked = mapIdentityToolkitError(
      403,
      "Requests to this API identitytoolkit.googleapis.com method are blocked. (API_KEY_SERVICE_BLOCKED)"
    );
    assert.equal(blocked.code, "permission-denied");
    assert.equal(blocked.details?.upstream, "API_KEY_SERVICE_BLOCKED");
    assert.equal(mapIdentityToolkitError(400, "OPERATION_NOT_ALLOWED").code, "permission-denied");
    assert.equal(mapIdentityToolkitError(400, "API key not valid. Please pass a valid API key.").code, "permission-denied");
  });

  it("classifies password abuse throttling as rate limited", () => {
    assert.equal(
      mapIdentityToolkitError(400, "TOO_MANY_ATTEMPTS_TRY_LATER").code,
      "rate-limited"
    );
  });

  it("extracts an upstream code for diagnostics without echoing the message", () => {
    assert.equal(extractUpstreamCode("API_KEY_SERVICE_BLOCKED"), "API_KEY_SERVICE_BLOCKED");
    assert.equal(
      extractUpstreamCode("Requests ... are blocked. (API_KEY_IP_ADDRESS_BLOCKED)"),
      "API_KEY_IP_ADDRESS_BLOCKED"
    );
    assert.equal(extractUpstreamCode("Incorrect email or password"), null);
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
