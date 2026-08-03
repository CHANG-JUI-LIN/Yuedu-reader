import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  decideTestFlightProRequest,
  normalizeTestFlightEmail,
} from "../src/testflightRequestPolicy.js";

describe("testflight request policy", () => {
  it("normalizes valid addresses to lowercase trimmed form", () => {
    assert.equal(normalizeTestFlightEmail("User@Example.com"), "user@example.com");
    assert.equal(normalizeTestFlightEmail("  user@example.com  "), "user@example.com");
  });

  it("rejects malformed addresses", () => {
    assert.equal(normalizeTestFlightEmail(""), null);
    assert.equal(normalizeTestFlightEmail("   "), null);
    assert.equal(normalizeTestFlightEmail("not-an-email"), null);
    assert.equal(normalizeTestFlightEmail("a@b"), null);
    assert.equal(normalizeTestFlightEmail("user@"), null);
    assert.equal(normalizeTestFlightEmail("@example.com"), null);
    assert.equal(normalizeTestFlightEmail("user@ example.com"), null);
    assert.equal(normalizeTestFlightEmail("user/a@example.com"), null);
    assert.equal(normalizeTestFlightEmail(12345), null);
    assert.equal(normalizeTestFlightEmail(undefined), null);
  });

  it("rejects addresses over 254 characters", () => {
    const tooLong = `user@${"a".repeat(250)}.com`;
    assert.equal(normalizeTestFlightEmail(tooLong), null);
  });

  it("allows the first request and only repeats the same email", () => {
    assert.equal(decideTestFlightProRequest(undefined, "user@example.com"), "accept");
    assert.equal(
      decideTestFlightProRequest("user@example.com", "user@example.com"),
      "alreadySubmitted"
    );
    assert.equal(
      decideTestFlightProRequest("user@example.com", "other@example.com"),
      "differentEmail"
    );
  });
});
