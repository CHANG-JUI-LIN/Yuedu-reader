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

  it("refuses to bind a free TestFlight (Sandbox) purchase", () => {
    // The leak: a Sandbox purchase costs nothing, so binding one handed Pro to
    // every beta tester who signed into the same account on the App Store build.
    assert.throws(() => assertTransactionCanBind({
      productId: "com.zhangruilin.yuedureader.pro.lifetime",
      appAccountToken: "token-a",
      environment: "Sandbox",
    }, "token-a"), /Only App Store purchases/);
    assert.throws(() => assertTransactionCanBind({
      productId: "com.zhangruilin.yuedureader.pro.lifetime",
      appAccountToken: "token-a",
    }, "token-a"), /Only App Store purchases/);
  });

  it("counts only production bindings toward the entitlement", () => {
    const now = Date.parse("2026-08-02T00:00:00Z");
    const lifetime = {active: true, expiresAt: null};

    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: "Production"}, now),
      true
    );
    // Already-stored Sandbox bindings stop counting the moment this deploys,
    // which is what stops the leak without a data migration.
    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: "Sandbox"}, now),
      false
    );
    assert.equal(
      bindingGrantsEntitlement({...lifetime, environment: undefined}, now),
      false
    );
    assert.equal(
      bindingGrantsEntitlement({active: false, expiresAt: null, environment: "Production"}, now),
      false
    );
    assert.equal(
      bindingGrantsEntitlement(
        {active: true, environment: "Production", expiresAt: {toMillis: () => now - 1}},
        now
      ),
      false
    );
    assert.equal(
      bindingGrantsEntitlement(
        {active: true, environment: "Production", expiresAt: {toMillis: () => now + 1}},
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
