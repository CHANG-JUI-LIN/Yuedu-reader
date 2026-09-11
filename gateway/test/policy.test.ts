import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {ApiError} from "../src/errors.js";
import {
  avatarObjectPath,
  recentAuthSatisfied,
  requireEmail,
  requirePassword,
  requireProviderId,
  sanitizeProfilePatch,
  selectEntitlement,
} from "../src/policy.js";

describe("recentAuthSatisfied", () => {
  it("accepts a token signed in moments ago", () => {
    const now = 1_000_000;
    assert.equal(recentAuthSatisfied(now - 5, now), true);
  });

  it("rejects a token older than the window", () => {
    const now = 1_000_000;
    assert.equal(recentAuthSatisfied(now - 11 * 60, now), false);
  });

  it("rejects a missing auth_time", () => {
    assert.equal(recentAuthSatisfied(undefined, 1_000_000), false);
  });

  it("tolerates small negative clock skew but not a future-dated token", () => {
    const now = 1_000_000;
    assert.equal(recentAuthSatisfied(now + 30, now), true);
    assert.equal(recentAuthSatisfied(now + 3600, now), false);
  });
});

describe("sanitizeProfilePatch", () => {
  it("accepts a display name and known preferences", () => {
    const patch = sanitizeProfilePatch({
      displayName: "  Reader  ",
      preferences: {readerFontSize: 18, theme: "dark", scrollMode: true},
    });
    assert.equal(patch.displayName, "Reader");
    assert.deepEqual(patch.preferences, {readerFontSize: 18, theme: "dark", scrollMode: true});
  });

  it("rejects privilege fields", () => {
    for (const field of ["uid", "email", "provider", "photoURL", "isProActive", "subscription"]) {
      assert.throws(
        () => sanitizeProfilePatch({[field]: "x"}),
        (error: unknown) => error instanceof ApiError && error.code === "invalid-argument"
      );
    }
  });

  it("drops unknown preference keys instead of writing them", () => {
    const patch = sanitizeProfilePatch({preferences: {readerFontSize: 18, admin: true}});
    assert.deepEqual(patch.preferences, {readerFontSize: 18});
  });

  it("rejects out-of-range numbers and wrong types", () => {
    assert.throws(() => sanitizeProfilePatch({preferences: {readerFontSize: -1}}));
    assert.throws(() => sanitizeProfilePatch({preferences: {readerFontSize: "18"}}));
    assert.throws(() => sanitizeProfilePatch({preferences: {scrollMode: 1}}));
  });

  it("validates header maps and color maps", () => {
    const patch = sanitizeProfilePatch({
      preferences: {
        readerHeaderFieldPositions: {title: "left"},
        readerTextColorOverrides: {dark: 0xFFFFFF},
      },
    });
    assert.deepEqual(patch.preferences, {
      readerHeaderFieldPositions: {title: "left"},
      readerTextColorOverrides: {dark: 0xFFFFFF},
    });
    assert.throws(() =>
      sanitizeProfilePatch({preferences: {readerTextColorOverrides: {dark: -1}}}));
  });

  it("rejects an empty patch", () => {
    assert.throws(() => sanitizeProfilePatch({}));
  });
});

describe("selectEntitlement", () => {
  const document = {
    isProActive: true,
    productIds: ["lifetime"],
    expiresAt: {toMillis: () => 42},
    sandboxIsProActive: false,
    sandboxProductIds: ["monthly"],
    sandboxExpiresAt: null,
  };

  it("reads the production half for a production build", () => {
    assert.deepEqual(selectEntitlement(document, "production"), {
      isProActive: true,
      productIds: ["lifetime"],
      expiresAtMilliseconds: 42,
    });
  });

  it("reads the sandbox half for a sandbox build", () => {
    assert.deepEqual(selectEntitlement(document, "sandbox"), {
      isProActive: false,
      productIds: ["monthly"],
      expiresAtMilliseconds: null,
    });
  });

  it("does not leak a production grant into sandbox", () => {
    const sandboxOnly = selectEntitlement(
      {isProActive: true, productIds: ["lifetime"], expiresAt: null},
      "sandbox"
    );
    assert.equal(sandboxOnly.isProActive, false);
  });
});

describe("input helpers", () => {
  it("normalizes and validates emails", () => {
    assert.equal(requireEmail("  a@b.co "), "a@b.co");
    assert.throws(() => requireEmail("not-an-email"));
    assert.throws(() => requireEmail("a//b@c.d"));
  });

  it("enforces the Firebase minimum password length", () => {
    assert.equal(requirePassword("123456"), "123456");
    assert.throws(() => requirePassword("12345"));
    assert.throws(() => requirePassword(123456));
  });

  it("allows only known provider ids", () => {
    assert.equal(requireProviderId("apple.com"), "apple.com");
    assert.throws(() => requireProviderId("phone"));
  });

  it("builds avatar paths only from identifier-safe uids", () => {
    assert.equal(avatarObjectPath("abc123"), "avatars/abc123.jpg");
    assert.throws(() => avatarObjectPath("../../etc/passwd"));
    assert.throws(() => avatarObjectPath("a/b"));
  });
});
