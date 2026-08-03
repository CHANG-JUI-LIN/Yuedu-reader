import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  assertBindingOwner,
  assertTransactionCanBind,
  bindingGrantsEntitlement,
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
      environment: "Production",
    }, "token-a"));
    assert.throws(() => assertTransactionCanBind({
      productId: "com.example.other",
      appAccountToken: "token-a",
      environment: "Production",
    }, "token-a"), /Unsupported product/);
    assert.throws(() => assertTransactionCanBind({
      productId: "com.zhangruilin.yuedureader.pro.monthly",
      appAccountToken: "token-b",
      environment: "Production",
    }, "token-a"), /different app account/);
  });

  it("binds a TestFlight (Sandbox) purchase so testers can buy too", () => {
    // Rejecting Sandbox here meant a tester's purchase was thrown away and
    // nothing ever unlocked in TestFlight. Environment is an isolation
    // dimension, not a reason to refuse.
    assert.doesNotThrow(() => assertTransactionCanBind({
      productId: "com.zhangruilin.yuedureader.pro.lifetime",
      appAccountToken: "token-a",
      environment: "Sandbox",
    }, "token-a"));
    assert.doesNotThrow(() => assertTransactionCanBind({
      productId: "com.zhangruilin.yuedureader.pro.monthly",
      appAccountToken: "token-a",
      environment: "Sandbox",
    }, "token-a"));
  });

  it("keeps TestFlight and App Store entitlements apart", () => {
    const now = Date.parse("2026-08-02T00:00:00Z");
    const lifetime = {active: true, expiresAt: null};

    // Each environment grants only its own build. This is the leak that made a
    // free TestFlight purchase unlock the App Store build for anyone signed
    // into the same account — and why signing out was what cleared it.
    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: "Production"}, "Production", now),
      true
    );
    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: "Sandbox"}, "Production", now),
      false
    );
    // ...but a tester still gets Pro in TestFlight from that same binding.
    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: "Sandbox"}, "Sandbox", now),
      true
    );
    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: "Production"}, "Sandbox", now),
      false
    );
    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: undefined}, "Production", now),
      false
    );
    assert.equal(
      bindingGrantsEntitlement(
        {active: false, expiresAt: null, environment: "Production"},
        "Production",
        now
      ),
      false
    );
    // A monthly subscription still expires inside its own environment.
    assert.equal(
      bindingGrantsEntitlement(
        {active: true, environment: "Production", expiresAt: {toMillis: () => now - 1}},
        "Production",
        now
      ),
      false
    );
    assert.equal(
      bindingGrantsEntitlement(
        {active: true, environment: "Sandbox", expiresAt: {toMillis: () => now - 1}},
        "Sandbox",
        now
      ),
      false
    );
    assert.equal(
      bindingGrantsEntitlement(
        {active: true, environment: "Production", expiresAt: {toMillis: () => now + 1}},
        "Production",
        now
      ),
      true
    );
  });

  it("reads the environment from transactions and server notifications", () => {
    assert.equal(environmentName({environment: "Production"}), "Production");
    assert.equal(environmentName({data: {environment: "Sandbox"}}), "Sandbox");
    assert.equal(environmentName({}), undefined);
  });
});
