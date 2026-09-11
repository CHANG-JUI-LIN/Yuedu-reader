import {ApiError, extractUpstreamCode, mapIdentityToolkitError} from "./errors.js";
import {logEvent} from "./logger.js";

/**
 * Thin client for the Identity Toolkit (Firebase Auth) REST API. The Gateway
 * uses the same endpoints the Firebase SDKs use, so existing users, UIDs,
 * providers and disabled/revoked semantics all stay authoritative in the
 * existing project. This is not an Admin "manage users" wrapper: passwords go
 * one way, inside a request, and are never stored or logged.
 */

export interface IdentitySession {
  idToken: string;
  refreshToken: string;
  expiresIn: number;
  localId: string;
}

export interface VerifiedAssertion {
  session: IdentitySession;
  /** Set when the credential already belongs to a different account. */
  pendingToken: string | null;
  providerId: string | null;
}

interface IdentityToolkitConfig {
  apiKey: string;
  upstreamTimeoutMs: number;
}

const IDENTITY_TOOLKIT_BASE = "https://identitytoolkit.googleapis.com/v1";
const SECURE_TOKEN_URL = "https://securetoken.googleapis.com/v1/token";

/**
 * Token Service requires the API key in the query string like every other
 * Identity Toolkit endpoint. The gateway's first refresh implementation omitted
 * it, so securetoken answered "Method doesn't allow unregistered callers" (403)
 * for every refresh while direct probes with ?key= worked. Exported so the URL
 * shape is unit-tested.
 */
export function secureTokenURL(apiKey: string): string {
  return `${SECURE_TOKEN_URL}?key=${encodeURIComponent(apiKey)}`;
}

async function postJson(
  config: IdentityToolkitConfig,
  url: string,
  body: Record<string, unknown>
): Promise<Record<string, unknown>> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(config.upstreamTimeoutMs),
    });
  } catch {
    throw new ApiError("upstream-unavailable", "The identity service is unreachable.");
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
  if (!response.ok) {
    const message = extractErrorMessage(parsed) ?? `identity toolkit error ${response.status}`;
    // Status + upstream code + a capped upstream message: enough to identify
    // the layer without logging request bodies, passwords or tokens.
    logEvent("identity toolkit rejected request", {
      status: response.status,
      upstream: extractUpstreamCode(message) ?? "unknown",
      detail: message.slice(0, 200),
    });
    throw mapIdentityToolkitError(response.status, message);
  }
  if (parsed === null || typeof parsed !== "object") {
    throw new ApiError("upstream-unavailable", "The identity service returned an invalid response.");
  }
  return parsed as Record<string, unknown>;
}

function extractErrorMessage(parsed: unknown): string | null {
  if (parsed === null || typeof parsed !== "object") return null;
  const error = (parsed as {error?: unknown}).error;
  if (typeof error === "string") return error;
  if (error !== null && typeof error === "object") {
    const message = (error as {message?: unknown}).message;
    if (typeof message === "string") return message;
  }
  return null;
}

function sessionFrom(data: Record<string, unknown>): IdentitySession {
  const idToken = data.idToken;
  const refreshToken = data.refreshToken;
  const localId = data.localId;
  if (typeof idToken !== "string" || typeof refreshToken !== "string" || typeof localId !== "string") {
    throw new ApiError("upstream-unavailable", "The identity service returned an incomplete session.");
  }
  const expiresIn = typeof data.expiresIn === "string" ? Number.parseInt(data.expiresIn, 10) : 3600;
  return {
    idToken,
    refreshToken,
    expiresIn: Number.isFinite(expiresIn) ? expiresIn : 3600,
    localId,
  };
}

/** `accounts:signInWithPassword` — existing email/password sign-in. */
export async function signInWithPassword(
  config: IdentityToolkitConfig,
  email: string,
  password: string
): Promise<IdentitySession> {
  const data = await postJson(
    config,
    `${IDENTITY_TOOLKIT_BASE}/accounts:signInWithPassword?key=${encodeURIComponent(config.apiKey)}`,
    {email, password, returnSecureToken: true}
  );
  return sessionFrom(data);
}

/** `accounts:signUp` — email/password registration with the same project. */
export async function signUpWithPassword(
  config: IdentityToolkitConfig,
  email: string,
  password: string
): Promise<IdentitySession> {
  const data = await postJson(
    config,
    `${IDENTITY_TOOLKIT_BASE}/accounts:signUp?key=${encodeURIComponent(config.apiKey)}`,
    {email, password, returnSecureToken: true}
  );
  return sessionFrom(data);
}

export interface IdpSignInInput {
  provider: "apple" | "google";
  idToken: string;
  rawNonce?: string;
  accessToken?: string;
  fullName?: {givenName?: string; familyName?: string};
  /** Existing user's ID token — present links the credential instead of signing in. */
  linkIdToken?: string;
}

/**
 * `accounts:signInWithIdp` — exchanges an Apple/Google credential. The provider
 * ID token signature is verified by Firebase itself; the Gateway never decodes
 * and trusts a JWT on its own.
 */
export async function signInWithIdp(
  config: IdentityToolkitConfig,
  input: IdpSignInInput
): Promise<VerifiedAssertion> {
  const postBody = new URLSearchParams();
  postBody.set("providerId", input.provider === "apple" ? "apple.com" : "google.com");
  postBody.set("id_token", input.idToken);
  if (input.rawNonce !== undefined && input.rawNonce !== "") {
    postBody.set("nonce", input.rawNonce);
  }
  if (input.accessToken !== undefined && input.accessToken !== "") {
    postBody.set("access_token", input.accessToken);
  }
  if (input.fullName !== undefined && (input.fullName.givenName !== undefined || input.fullName.familyName !== undefined)) {
    postBody.set("user", JSON.stringify({name: {
      ...(input.fullName.givenName === undefined ? {} : {firstName: input.fullName.givenName}),
      ...(input.fullName.familyName === undefined ? {} : {lastName: input.fullName.familyName}),
    }}));
  }

  const body: Record<string, unknown> = {
    requestUri: "http://localhost",
    postBody: postBody.toString(),
    returnSecureToken: true,
    returnIdpCredential: true,
    autoCreate: true,
  };
  if (input.linkIdToken !== undefined) {
    body.idToken = input.linkIdToken;
  }

  const data = await postJson(
    config,
    `${IDENTITY_TOOLKIT_BASE}/accounts:signInWithIdp?key=${encodeURIComponent(config.apiKey)}`,
    body
  );

  if (data.needConfirmation === true) {
    const pendingToken = typeof data.pendingToken === "string" ? data.pendingToken : null;
    if (pendingToken === null) {
      throw new ApiError("credential-already-in-use", "This sign-in method belongs to another account.");
    }
    // The credential belongs to a different account. We do not silently sign
    // into it or merge anything; the client must confirm the switch.
    throw new ApiError(
      "credential-already-in-use",
      "This sign-in method belongs to another account.",
      {pendingToken}
    );
  }

  return {
    session: sessionFrom(data),
    pendingToken: null,
    providerId: typeof data.providerId === "string" ? data.providerId : null,
  };
}

/** Signs into the account owning a pending credential from a failed link. */
export async function signInWithPendingToken(
  config: IdentityToolkitConfig,
  pendingToken: string
): Promise<IdentitySession> {
  const data = await postJson(
    config,
    `${IDENTITY_TOOLKIT_BASE}/accounts:signInWithIdp?key=${encodeURIComponent(config.apiKey)}`,
    {
      requestUri: "http://localhost",
      pendingToken,
      returnSecureToken: true,
      autoCreate: true,
    }
  );
  return sessionFrom(data);
}

/** `securetoken` refresh — the only token refresh path; no bespoke JWT scheme. */
export async function refreshSession(
  config: IdentityToolkitConfig,
  refreshToken: string
): Promise<IdentitySession> {
  let response: Response;
  try {
    response = await fetch(secureTokenURL(config.apiKey), {
      method: "POST",
      headers: {"Content-Type": "application/x-www-form-urlencoded"},
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: refreshToken,
      }).toString(),
      signal: AbortSignal.timeout(config.upstreamTimeoutMs),
    });
  } catch {
    throw new ApiError("upstream-unavailable", "The identity service is unreachable.");
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
  if (!response.ok) {
    const message = extractErrorMessage(parsed) ?? `secure token error ${response.status}`;
    logEvent("token service rejected request", {
      status: response.status,
      upstream: extractUpstreamCode(message) ?? "unknown",
      detail: message.slice(0, 200),
    });
    throw mapIdentityToolkitError(response.status, message);
  }
  if (parsed === null || typeof parsed !== "object") {
    throw new ApiError("upstream-unavailable", "The identity service returned an invalid response.");
  }
  const data = parsed as Record<string, unknown>;
  const idToken = data.id_token;
  const newRefreshToken = data.refresh_token;
  const userId = data.user_id;
  if (typeof idToken !== "string" || typeof newRefreshToken !== "string" || typeof userId !== "string") {
    throw new ApiError("upstream-unavailable", "The identity service returned an incomplete session.");
  }
  const expiresIn = typeof data.expires_in === "string" ? Number.parseInt(data.expires_in, 10) : 3600;
  return {
    idToken,
    refreshToken: newRefreshToken,
    expiresIn: Number.isFinite(expiresIn) ? expiresIn : 3600,
    localId: userId,
  };
}

/** `accounts:update` — links an email/password credential to the signed-in user. */
export async function linkEmailPassword(
  config: IdentityToolkitConfig,
  idToken: string,
  email: string,
  password: string
): Promise<void> {
  await postJson(
    config,
    `${IDENTITY_TOOLKIT_BASE}/accounts:update?key=${encodeURIComponent(config.apiKey)}`,
    {idToken, email, password, returnSecureToken: true}
  );
}

/**
 * `accounts:revokeToken` — revokes an Apple authorization code, the same call
 * `Auth.revokeToken(withAuthorizationCode:)` makes. Apple requires this when an
 * account is deleted.
 */
export async function revokeAppleAuthorizationCode(
  config: IdentityToolkitConfig,
  idToken: string,
  authorizationCode: string
): Promise<void> {
  await postJson(
    config,
    `${IDENTITY_TOOLKIT_BASE}/accounts:revokeToken?key=${encodeURIComponent(config.apiKey)}`,
    {
      providerId: "apple.com",
      tokenType: "3",
      token: authorizationCode,
      idToken,
    }
  );
}
