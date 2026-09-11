import {Router} from "express";
import {FieldValue, Timestamp} from "firebase-admin/firestore";

import {authenticatedUser, requireAuth} from "../auth.js";
import type {GatewayContext} from "../context.js";
import {ApiError, errorBody} from "../errors.js";
import {sanitizeProfilePatch} from "../policy.js";

export function profileRouter(context: GatewayContext): Router {
  const router = Router();

  router.get("/", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const snapshot = await context.firestore.collection("users").doc(user.uid).get();
      if (!snapshot.exists) {
        response.json({profile: null});
        return;
      }
      response.json({profile: profilePayload(snapshot.data() ?? {})});
    } catch (error) {
      next(error);
    }
  });

  router.put("/", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const patch = sanitizeProfilePatch(request.body);
      const reference = context.firestore.collection("users").doc(user.uid);
      const snapshot = await reference.get();
      const existing = snapshot.data() ?? {};
      const record = await context.auth.getUser(user.uid);

      const existingPreferences = isRecord(existing.preferences) ? existing.preferences : {};
      const data: Record<string, unknown> = {
        uid: user.uid,
        email: (record.email ?? existing.email ?? "") as string,
        provider: providerDisplayName(record.providerData.map((provider) => provider.providerId)),
        displayName: patch.displayName ?? (typeof existing.displayName === "string" ? existing.displayName : ""),
        createdAt: existing.createdAt ?? FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      };
      // photoURL is server-managed: only the avatar endpoints may change it.
      data.photoURL = typeof existing.photoURL === "string" ? existing.photoURL : "";
      if (patch.preferences !== undefined) {
        data.preferences = {...existingPreferences, ...patch.preferences};
      } else if (!isRecord(existing.preferences)) {
        data.preferences = {};
      }

      await reference.set(data, {merge: true});
      const updated = await reference.get();
      response.json({profile: profilePayload(updated.data() ?? {})});
    } catch (error) {
      next(error);
    }
  });

  router.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown profile route.");
    response.status(error.status).json(errorBody(error));
  });

  return router;
}

export function profilePayload(data: Record<string, unknown>): Record<string, unknown> {
  return {
    uid: typeof data.uid === "string" ? data.uid : "",
    displayName: typeof data.displayName === "string" ? data.displayName : "",
    email: typeof data.email === "string" ? data.email : "",
    provider: typeof data.provider === "string" ? data.provider : "",
    photoURL: typeof data.photoURL === "string" && data.photoURL !== "" ? data.photoURL : null,
    createdAt: isoString(data.createdAt),
    updatedAt: isoString(data.updatedAt),
    preferences: isRecord(data.preferences) ? data.preferences : {},
  };
}

function isoString(value: unknown): string {
  if (value instanceof Timestamp) return value.toDate().toISOString();
  if (value instanceof Date) return value.toISOString();
  return new Date(0).toISOString();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function providerDisplayName(providerIds: string[]): string {
  const first = providerIds[0];
  switch (first) {
    case "google.com":
      return "Google";
    case "apple.com":
      return "Apple";
    case "password":
      return "Email";
    default:
      return first ?? "Firebase";
  }
}
