import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  assertBindingOwner,
  assertTransactionCanBind,
  effectiveEntitlement,
  environmentName,
  transactionIsActive,
} from "../src/entitlementPolicy.js";

describe("entitlement policy", () => {
  it("keeps Pro active when either StoreKit or the signed-in account is active", () => {
    assert.equal(effectiveEntitlement(false, false), false);
    assert.equal(effectiveEntitlement(true, false), true);
    assert.equal(effectiveEntitlement(false, true), true);
    assert.equal(effectiveEntitlement(true, true), true);
  });

  it("rejects a transaction already bound to another account", () => {
    assert.doesNotThrow(() => assertBindingOwner(undefined, "user-a"));
    assert.doesNotThrow(() => assertBindingOwner("user-a", "user-a"));
    assert.throws(
      () => assertBindingOwner("user-b", "user-a"),
      /already bound to another account/
    );
  });

  it("treats lifetime and unexpired subscription transactions as active", () => {
    const now = Date.parse("2026-07-18T00:00:00Z");

    assert.equal(transactionIsActive({revocationDate: undefined}, now), true);
    assert.equal(transactionIsActive({revocationDate: now - 1}, now), false);
    assert.equal(transactionIsActive({expiresDate: now + 1}, now), true);
    assert.equal(transactionIsActive({expiresDate: now}, now), false);
  });

  it("accepts only Yuedu products with a matching account token", () => {
    assert.doesNotThrow(() => assertTransactionCanBind({
      productId: "com.zhangruilin.yuedureader.pro.monthly",
      appAccountToken: "token-a",
    }, "token-a"));
    assert.throws(() => assertTransactionCanBind({
      productId: "com.example.other",
      appAccountToken: "token-a",
    }, "token-a"), /Unsupported product/);
    assert.throws(() => assertTransactionCanBind({
      productId: "com.zhangruilin.yuedureader.pro.monthly",
      appAccountToken: "token-b",
    }, "token-a"), /different app account/);
  });

  it("reads the environment from transactions and server notifications", () => {
    assert.equal(environmentName({environment: "Production"}), "Production");
    assert.equal(environmentName({data: {environment: "Sandbox"}}), "Sandbox");
    assert.equal(environmentName({}), undefined);
  });
});
