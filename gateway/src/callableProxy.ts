import type {Auth} from "firebase-admin/auth";

import {ApiError} from "./errors.js";
import {logError} from "./logger.js";

/**
 * Calls the project's existing v2 callables on behalf of the verified user.
 *
 * The Gateway does not reimplement subscription entitlement logic. It mints a
 * short-lived Firebase session for the *already verified* uid through the
 * official custom-token exchange, then calls the whitelisted callable with the
 * standard callable protocol. Upstream remains the single source of entitlement
 * truth, and App Check is unchanged (no callable enforces it today; if one ever
 * does, the server-to-server path must be revisited rather than bypassed).
 */
export const CALLABLE_WHITELIST = [
  "getSubscriptionAccountToken",
  "bindSubscriptionPurchase",
  "deleteSubscriptionAccountData",
  "requestTestFlightAccess",
] as const;

export type CallableName = (typeof CALLABLE_WHITELIST)[number];

export interface CallableCaller {
  call(name: CallableName, uid: string, data: Record<string, unknown>): Promise<Record<string, unknown>>;
}

interface CallableProxyOptions {
  projectId: string;
  region: string;
  apiKey: string;
  upstreamTimeoutMs: number;
  auth: Auth;
}

const IDENTITY_TOOLKIT_BASE = "https://identitytoolkit.googleapis.com/v1";

export function createCallableCaller(options: CallableProxyOptions): CallableCaller {
  return {
    async call(name, uid, data) {
      if (!(CALLABLE_WHITELIST as readonly string[]).includes(name)) {
        throw new ApiError("invalid-argument", "Unsupported server operation.");
      }
      const idToken = await mintSessionIdToken(options, uid);
      const url = `https://${options.region}-${options.projectId}.cloudfunctions.net/${name}`;
      let response: Response;
      try {
        response = await fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${idToken}`,
          },
          body: JSON.stringify({data}),
          signal: AbortSignal.timeout(options.upstreamTimeoutMs),
        });
      } catch (error) {
        logError(`callable ${name} unreachable`, error);
        throw new ApiError("upstream-unavailable", "The server operation is temporarily unavailable.");
      }

      const text = await response.text();
      let parsed: unknown = null;
      if (text !== "") {
        try {
          parsed = JSON.parse(text);
        } catch {
          parsed = null;
        }
      }
      if (parsed === null || typeof parsed !== "object") {
        throw new ApiError("upstream-unavailable", "The server operation returned an invalid response.");
      }
      const payload = parsed as Record<string, unknown>;
      if (!response.ok) {
        throw callableError(payload, response.status);
      }
      const result = payload.result;
      if (result === undefined) {
        throw new ApiError("upstream-unavailable", "The server operation returned an invalid response.");
      }
      if (result === null) return {};
      if (typeof result !== "object" || Array.isArray(result)) {
        // A callable may legitimately return a scalar; keep the contract object-shaped.
        return {value: result as unknown};
      }
      return result as Record<string, unknown>;
    },
  };
}

async function mintSessionIdToken(options: CallableProxyOptions, uid: string): Promise<string> {
  const customToken = await options.auth.createCustomToken(uid);
  let response: Response;
  try {
    response = await fetch(
      `${IDENTITY_TOOLKIT_BASE}/accounts:signInWithCustomToken?key=${encodeURIComponent(options.apiKey)}`,
      {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: customToken, returnSecureToken: true}),
        signal: AbortSignal.timeout(options.upstreamTimeoutMs),
      }
    );
  } catch (error) {
    logError("custom token exchange unreachable", error);
    throw new ApiError("upstream-unavailable", "The server operation is temporarily unavailable.");
  }
  const text = await response.text();
  if (!response.ok) {
    logError("custom token exchange rejected", new Error(`status ${response.status}`));
    throw new ApiError("upstream-unavailable", "The server operation is temporarily unavailable.");
  }
  let parsed: unknown = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = null;
  }
  const idToken = parsed !== null && typeof parsed === "object" ?
    (parsed as {idToken?: unknown}).idToken :
    undefined;
  if (typeof idToken !== "string") {
    throw new ApiError("upstream-unavailable", "The server operation returned an invalid session.");
  }
  return idToken;
}

const GRPC_CODE_BY_STATUS: Record<string, number> = {
  OK: 0,
  CANCELLED: 1,
  UNKNOWN: 2,
  INVALID_ARGUMENT: 3,
  DEADLINE_EXCEEDED: 4,
  NOT_FOUND: 5,
  ALREADY_EXISTS: 6,
  PERMISSION_DENIED: 7,
  RESOURCE_EXHAUSTED: 8,
  FAILED_PRECONDITION: 9,
  ABORTED: 10,
  OUT_OF_RANGE: 11,
  UNIMPLEMENTED: 12,
  INTERNAL: 13,
  UNAVAILABLE: 14,
  DATA_LOSS: 15,
  UNAUTHENTICATED: 16,
};

export function callableError(payload: Record<string, unknown>, httpStatus: number): ApiError {
  const rawError = payload.error;
  const error = rawError !== null && typeof rawError === "object" ? rawError as Record<string, unknown> : {};
  const status = typeof error.status === "string" ? error.status : "UNKNOWN";
  const message = typeof error.message === "string" ? error.message : "The server operation failed.";
  const grpcCode = GRPC_CODE_BY_STATUS[status] ?? 2;
  const details = {grpcStatus: status, grpcCode};

  switch (status) {
    case "INVALID_ARGUMENT":
      return new ApiError("invalid-argument", message, details);
    case "UNAUTHENTICATED":
      return new ApiError("unauthenticated", message, details);
    case "PERMISSION_DENIED":
      return new ApiError("permission-denied", message, details);
    case "NOT_FOUND":
      return new ApiError("not-found", message, details);
    case "ALREADY_EXISTS":
    case "FAILED_PRECONDITION":
    case "ABORTED":
      return new ApiError("conflict", message, details);
    case "RESOURCE_EXHAUSTED":
      return new ApiError("rate-limited", message, details);
    case "DEADLINE_EXCEEDED":
    case "UNAVAILABLE":
      return new ApiError("upstream-unavailable", message, details);
    default:
      if (httpStatus >= 500) {
        return new ApiError("upstream-unavailable", message, details);
      }
      return new ApiError("internal", message, details);
  }
}
