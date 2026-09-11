import {Router} from "express";

import {accountUserPayload, authenticatedUser, requireAuth} from "../auth.js";
import type {GatewayContext} from "../context.js";
import {ApiError, errorBody} from "../errors.js";
import {
  linkEmailPassword,
  refreshSession,
  signInWithIdp,
  signInWithPassword,
  signInWithPendingToken,
  signUpWithPassword,
  type IdpSignInInput,
} from "../identityToolkit.js";
import {
  requireEmail,
  requirePassword,
  requireProvider,
  requireRecentAuth,
  requireShortString,
} from "../policy.js";
import {applyFirstAppleDisplayName, buildSessionPayload} from "../sessionResponse.js";

export function authRouter(context: GatewayContext): Router {
  const router = Router();
  const toolkit = {apiKey: context.config.apiKey, upstreamTimeoutMs: context.config.upstreamTimeoutMs};

  router.post("/email/signin", async (request, response, next) => {
    try {
      const body = asObject(request.body);
      const email = requireEmail(body.email);
      const password = requirePassword(body.password);
      const session = await signInWithPassword(toolkit, email, password);
      response.json(await buildSessionPayload(context.auth, session));
    } catch (error) {
      next(error);
    }
  });

  router.post("/email/signup", async (request, response, next) => {
    try {
      const body = asObject(request.body);
      const email = requireEmail(body.email);
      const password = requirePassword(body.password);
      const session = await signUpWithPassword(toolkit, email, password);
      response.status(201).json(await buildSessionPayload(context.auth, session));
    } catch (error) {
      next(error);
    }
  });

  router.post("/idp", async (request, response, next) => {
    try {
      const body = asObject(request.body);
      const input = readIdpInput(body, requireProvider(body.provider));
      const assertion = await signInWithIdp(toolkit, input);
      await applyFirstAppleDisplayName(context.auth, assertion.session.localId, input);
      response.json(await buildSessionPayload(context.auth, assertion.session));
    } catch (error) {
      next(error);
    }
  });

  router.post("/pending", async (request, response, next) => {
    try {
      const body = asObject(request.body);
      const pendingToken = requireShortString(body.pendingToken, "pending token", 4096);
      const session = await signInWithPendingToken(toolkit, pendingToken);
      response.json(await buildSessionPayload(context.auth, session));
    } catch (error) {
      next(error);
    }
  });

  router.post("/refresh", async (request, response, next) => {
    try {
      const body = asObject(request.body);
      const refreshToken = requireShortString(body.refreshToken, "refresh token", 4096);
      const session = await refreshSession(toolkit, refreshToken);
      response.json(await buildSessionPayload(context.auth, session));
    } catch (error) {
      next(error);
    }
  });

  /**
   * Sign-out is local on the client; revoking refresh tokens on the server
   * would sign the user out of every device, which the current app does not do.
   * `revokeAllDevices` is opt-in and exists for account-security flows.
   */
  router.post("/logout", requireAuth(context.auth), async (request, response, next) => {
    try {
      const body = request.body === undefined ? {} : asObject(request.body);
      const user = authenticatedUser(request);
      if (body.revokeAllDevices === true) {
        await context.auth.revokeRefreshTokens(user.uid);
      }
      response.json({signedOut: true, revokedAllDevices: body.revokeAllDevices === true});
    } catch (error) {
      next(error);
    }
  });

  /** Server-authoritative account record for session restore. */
  router.get("/session", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const record = await context.auth.getUser(user.uid);
      response.json({user: accountUserPayload(record)});
    } catch (error) {
      next(error);
    }
  });

  /**
   * Links an email/password credential to the signed-in account. Sensitive, so
   * it requires a recent sign-in rather than just an unexpired token.
   */
  router.post("/link/email", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      requireRecentAuth(user.authTime, Math.floor(Date.now() / 1000));
      const body = asObject(request.body);
      const email = requireEmail(body.email);
      const password = requirePassword(body.password);
      const record = await context.auth.getUser(user.uid);
      if (record.providerData.some((provider) => provider.providerId === "password")) {
        throw new ApiError("provider-already-linked", "Email sign-in is already linked.");
      }
      const header = bearerToken(request);
      await linkEmailPassword(toolkit, header, email, password);
      response.json({linked: true});
    } catch (error) {
      next(error);
    }
  });

  /** Links an Apple/Google credential to the signed-in account (recent auth required). */
  router.post("/link/idp", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      requireRecentAuth(user.authTime, Math.floor(Date.now() / 1000));
      const body = asObject(request.body);
      const provider = requireProvider(body.provider);
      const input = readIdpInput(body, provider);
      const record = await context.auth.getUser(user.uid);
      const providerId = provider === "apple" ? "apple.com" : "google.com";
      if (record.providerData.some((data) => data.providerId === providerId)) {
        throw new ApiError("provider-already-linked", "This sign-in method is already linked.");
      }
      input.linkIdToken = bearerToken(request);
      try {
        await signInWithIdp(toolkit, input);
      } catch (error) {
        if (error instanceof ApiError && error.code === "credential-already-in-use") {
          throw error;
        }
        throw error;
      }
      response.json({linked: true});
    } catch (error) {
      next(error);
    }
  });

  /** Removes one sign-in method; the last one is never removable. */
  router.post("/unlink", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      requireRecentAuth(user.authTime, Math.floor(Date.now() / 1000));
      const body = asObject(request.body);
      const providerId = requireShortString(body.providerId, "provider id", 120);
      if (!["google.com", "apple.com", "password"].includes(providerId)) {
        throw new ApiError("invalid-argument", "Unsupported provider id.");
      }
      const record = await context.auth.getUser(user.uid);
      const linked = record.providerData.map((provider) => provider.providerId);
      if (!linked.includes(providerId)) {
        throw new ApiError("not-found", "This sign-in method is not linked.");
      }
      if (linked.length <= 1) {
        throw new ApiError("cannot-unlink-last-provider", "The last sign-in method cannot be removed.");
      }
      await context.auth.updateUser(user.uid, {providersToUnlink: [providerId]});
      const updated = await context.auth.getUser(user.uid);
      response.json({unlinked: true, user: accountUserPayload(updated)});
    } catch (error) {
      next(error);
    }
  });

  router.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown auth route.");
    response.status(error.status).json(errorBody(error));
  });

  return router;
}

function asObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError("invalid-argument", "Expected a JSON object.");
  }
  return value as Record<string, unknown>;
}

function readIdpInput(body: Record<string, unknown>, provider: "apple" | "google"): IdpSignInInput {
  const input: IdpSignInInput = {
    provider,
    idToken: requireShortString(body.idToken, "identity token", 20_000),
  };
  if (body.rawNonce !== undefined) {
    input.rawNonce = requireShortString(body.rawNonce, "nonce", 512);
  }
  if (body.accessToken !== undefined) {
    input.accessToken = requireShortString(body.accessToken, "access token", 20_000);
  }
  if (body.fullName !== undefined && body.fullName !== null) {
    const fullName = asObject(body.fullName);
    input.fullName = {};
    if (typeof fullName.givenName === "string" && fullName.givenName.length <= 80) {
      input.fullName.givenName = fullName.givenName;
    }
    if (typeof fullName.familyName === "string" && fullName.familyName.length <= 80) {
      input.fullName.familyName = fullName.familyName;
    }
  }
  return input;
}

function bearerToken(request: {header(name: string): string | undefined}): string {
  const match = /^Bearer\s+(.+)$/i.exec((request.header("authorization") ?? "").trim());
  if (match === null || match[1] === undefined) {
    throw new ApiError("unauthenticated", "Sign in to continue.");
  }
  return match[1];
}
