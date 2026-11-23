import {Router} from "express";

import {authenticatedUser, requireAuth} from "../auth.js";
import type {GatewayContext} from "../context.js";
import {ApiError, errorBody} from "../errors.js";
import {
  bindEntitlementResult,
  requireEmail,
  requireShortString,
  selectEntitlement,
  type SubscriptionEnvironment,
} from "../policy.js";

export function subscriptionRouter(context: GatewayContext): Router {
  const router = Router();

  /**
   * Reads `entitlements/{uid}` through the Admin SDK because the client cannot
   * reach Firestore. Only the document for the verified uid is ever touched, and
   * the environment the client names selects which half of the document is
   * returned. A missing document stays "no information" — never "not Pro".
   */
  router.get("/entitlement", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const environment = readEnvironment(request.query.environment);
      const snapshot = await context.firestore.collection("entitlements").doc(user.uid).get();
      if (!snapshot.exists) {
        response.json({exists: false, environment});
        return;
      }
      const entitlement = selectEntitlement(snapshot.data() ?? {}, environment);
      response.json({exists: true, environment, ...entitlement});
    } catch (error) {
      next(error);
    }
  });

  router.get("/account-token", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const result = await context.callables.call("getSubscriptionAccountToken", user.uid, {});
      const token = result.token;
      if (typeof token !== "string" || !/^[0-9a-fA-F-]{36}$/.test(token)) {
        throw new ApiError("upstream-unavailable", "The server returned an invalid account token.");
      }
      response.json({token});
    } catch (error) {
      next(error);
    }
  });

  router.post("/bind", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const body = asObject(request.body);
      const signedTransaction = requireShortString(body.signedTransaction, "signed transaction", 100_000);
      const result = await context.callables.call("bindSubscriptionPurchase", user.uid, {signedTransaction});
      response.json(bindEntitlementResult(result));
    } catch (error) {
      next(error);
    }
  });

  router.delete("/account-data", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      await context.callables.call("deleteSubscriptionAccountData", user.uid, {});
      response.json({deleted: true});
    } catch (error) {
      next(error);
    }
  });

  router.post("/testflight-access", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const result = await context.callables.call("verifyTestFlightAccess", user.uid, {});
      if (typeof result.allowed !== "boolean") throw new ApiError("upstream-unavailable", "Invalid membership response.");
      response.set("Cache-Control", "no-store").json({allowed: result.allowed});
    } catch (error) {
      next(error);
    }
  });

  router.post("/testflight-request", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const body = asObject(request.body);
      const email = requireEmail(body.email);
      const result = await context.callables.call("requestTestFlightAccess", user.uid, {email});
      response.json({
        alreadySubmitted: result.alreadySubmitted === true,
        status: typeof result.status === "string" ? result.status : "pending",
      });
    } catch (error) {
      next(error);
    }
  });

  router.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown subscription route.");
    response.status(error.status).json(errorBody(error));
  });

  return router;
}

function readEnvironment(value: unknown): SubscriptionEnvironment {
  if (value === "sandbox") return "sandbox";
  if (value === undefined || value === "production") return "production";
  throw new ApiError("invalid-argument", "Unsupported subscription environment.");
}

function asObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError("invalid-argument", "Expected a JSON object.");
  }
  return value as Record<string, unknown>;
}
