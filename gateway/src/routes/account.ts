import {Router} from "express";

import {accountUserPayload, authenticatedUser, requireAuth} from "../auth.js";
import type {GatewayContext} from "../context.js";
import {runAccountDeletion} from "../deletion.js";
import {ApiError, errorBody} from "../errors.js";
import {signInWithIdp, signInWithPassword} from "../identityToolkit.js";
import {requirePassword, requireShortString} from "../policy.js";

export function accountRouter(context: GatewayContext): Router {
  const router = Router();
  const toolkit = {apiKey: context.config.apiKey, upstreamTimeoutMs: context.config.upstreamTimeoutMs};

  /** Server-authoritative account record (used on session restore). */
  router.get("/me", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const record = await context.auth.getUser(user.uid);
      response.json({user: accountUserPayload(record)});
    } catch (error) {
      next(error);
    }
  });

  /**
   * Deletes the signed-in account. The credential is re-verified here — an
   * unexpired token alone is not enough — and the Auth user is removed last so
   * a partial failure stays retryable. The body is never logged.
   */
  router.post("/delete", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const body = requireObject(request.body);
      const reauth = requireObject(body.reauth);
      const record = await context.auth.getUser(user.uid);
      const linked = new Set(record.providerData.map((provider) => provider.providerId));

      const provider = reauth.provider;
      let appleAuthorizationCode: string | null = null;
      let freshIdToken = bearerToken(request);

      switch (provider) {
        case "password": {
          if (!linked.has("password")) {
            throw new ApiError("invalid-argument", "Email sign-in is not linked to this account.");
          }
          const accountEmail = record.email;
          if (accountEmail === undefined || accountEmail === "") {
            throw new ApiError("invalid-argument", "This account has no email address.");
          }
          const password = requirePassword(reauth.password);
          const session = await signInWithPassword(toolkit, accountEmail, password);
          if (session.localId !== user.uid) {
            throw new ApiError("invalid-credentials", "The credential belongs to a different account.");
          }
          freshIdToken = session.idToken;
          break;
        }
        case "apple": {
          if (!linked.has("apple.com")) {
            throw new ApiError("invalid-argument", "Apple sign-in is not linked to this account.");
          }
          const idToken = requireShortString(reauth.idToken, "identity token", 20_000);
          const rawNonce = requireShortString(reauth.rawNonce, "nonce", 512);
          const session = await signInWithIdp(toolkit, {provider: "apple", idToken, rawNonce}).then(
            (assertion) => assertion.session
          );
          if (session.localId !== user.uid) {
            throw new ApiError("invalid-credentials", "The credential belongs to a different account.");
          }
          freshIdToken = session.idToken;
          if (typeof reauth.appleAuthorizationCode === "string" && reauth.appleAuthorizationCode !== "") {
            appleAuthorizationCode = requireShortString(
              reauth.appleAuthorizationCode,
              "authorization code",
              8192
            );
          }
          break;
        }
        case "google": {
          if (!linked.has("google.com")) {
            throw new ApiError("invalid-argument", "Google sign-in is not linked to this account.");
          }
          const idToken = requireShortString(reauth.idToken, "identity token", 20_000);
          const accessToken = typeof reauth.accessToken === "string" && reauth.accessToken !== "" ?
            requireShortString(reauth.accessToken, "access token", 20_000) :
            undefined;
          const assertion = await signInWithIdp(toolkit, {
            provider: "google",
            idToken,
            ...(accessToken === undefined ? {} : {accessToken}),
          });
          if (assertion.session.localId !== user.uid) {
            throw new ApiError("invalid-credentials", "The credential belongs to a different account.");
          }
          freshIdToken = assertion.session.idToken;
          break;
        }
        default:
          throw new ApiError("invalid-argument", "A supported re-authentication provider is required.");
      }

      const job = await runAccountDeletion(context, user.uid, appleAuthorizationCode, freshIdToken);
      response.json({deleted: true, job});
    } catch (error) {
      next(error);
    }
  });

  /** Resume diagnostics for a deletion that failed before the Auth user was removed. */
  router.get("/deletion-status", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const snapshot = await context.firestore.collection("accountDeletionJobs").doc(user.uid).get();
      if (!snapshot.exists) {
        response.json({job: null});
        return;
      }
      response.json({job: snapshot.data() ?? null});
    } catch (error) {
      next(error);
    }
  });

  router.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown account route.");
    response.status(error.status).json(errorBody(error));
  });

  return router;
}

function requireObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError("invalid-argument", "Expected a JSON object.");
  }
  return value as Record<string, unknown>;
}

function bearerToken(request: {header(name: string): string | undefined}): string {
  const match = /^Bearer\s+(.+)$/i.exec((request.header("authorization") ?? "").trim());
  if (match === null || match[1] === undefined) {
    throw new ApiError("unauthenticated", "Sign in to continue.");
  }
  return match[1];
}
