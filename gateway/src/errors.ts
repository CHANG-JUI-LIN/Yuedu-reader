/**
 * Client-facing error codes. They are stable strings the iOS app maps to UI;
 * HTTP status is derived from them, so a route never has to invent a status.
 */
export type ApiErrorCode =
  | "invalid-argument"
  | "invalid-credentials"
  | "email-exists"
  | "user-disabled"
  | "user-not-found"
  | "unauthenticated"
  | "reauth-required"
  | "provider-already-linked"
  | "credential-already-in-use"
  | "cannot-unlink-last-provider"
  | "permission-denied"
  | "not-found"
  | "conflict"
  | "rate-limited"
  | "upstream-unavailable"
  | "cleanup-failed"
  | "apple-revoke-failed"
  | "payload-too-large"
  | "unsupported-media-type"
  | "internal";

const statusByCode: Record<ApiErrorCode, number> = {
  "invalid-argument": 400,
  "invalid-credentials": 401,
  "email-exists": 409,
  "user-disabled": 403,
  "user-not-found": 404,
  unauthenticated: 401,
  "reauth-required": 401,
  "provider-already-linked": 409,
  "credential-already-in-use": 409,
  "cannot-unlink-last-provider": 409,
  "permission-denied": 403,
  "not-found": 404,
  conflict: 409,
  "rate-limited": 429,
  "upstream-unavailable": 503,
  "cleanup-failed": 502,
  "apple-revoke-failed": 502,
  "payload-too-large": 413,
  "unsupported-media-type": 415,
  internal: 500,
};

export class ApiError extends Error {
  readonly code: ApiErrorCode;
  readonly status: number;
  readonly details?: Record<string, unknown>;

  constructor(code: ApiErrorCode, message: string, details?: Record<string, unknown>) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = statusByCode[code];
    this.details = details;
  }
}

export function errorBody(error: ApiError): {error: {code: string; message: string; details?: Record<string, unknown>}} {
  return {
    error: {
      code: error.code,
      message: error.message,
      ...(error.details === undefined ? {} : {details: error.details}),
    },
  };
}

/**
 * Express body-parser raises its own errors for oversized bodies. Map them to
 * the same structured contract instead of a generic 500.
 */
export function mapBodyParserError(error: unknown): ApiError | null {
  if (error === null || typeof error !== "object") return null;
  const type = (error as {type?: unknown}).type;
  if (type === "entity.too.large") {
    return new ApiError("payload-too-large", "The request body is too large.");
  }
  return null;
}

/**
 * Identity Toolkit errors arrive as `{error: {message: "EMAIL_EXISTS"}}` with an
 * HTTP status. Map the messages the app actually distinguishes; everything else
 * becomes a generic code so we never echo raw upstream text. The upstream code
 * (when identifiable) is attached as `details.upstream` so a caller can see
 * which layer rejected the request without server log access.
 */
export function mapIdentityToolkitError(status: number, message: string): ApiError {
  const normalized = message.toUpperCase();
  const code = extractUpstreamCode(message);
  const details = code === null ? {upstreamStatus: status} : {upstreamStatus: status, upstream: code};

  if (normalized.includes("EMAIL_EXISTS")) {
    return new ApiError("email-exists", "An account with this email already exists.", details);
  }
  if (normalized.includes("EMAIL_NOT_FOUND")) {
    return new ApiError("invalid-credentials", "Incorrect email or password.", details);
  }
  if (normalized.includes("INVALID_PASSWORD") || normalized.includes("INVALID_LOGIN_CREDENTIALS")) {
    return new ApiError("invalid-credentials", "Incorrect email or password.", details);
  }
  if (normalized.includes("USER_DISABLED")) {
    return new ApiError("user-disabled", "This account has been disabled.", details);
  }
  if (normalized.includes("USER_NOT_FOUND")) {
    return new ApiError("user-not-found", "This account no longer exists.", details);
  }
  if (normalized.includes("CREDENTIAL_TOO_OLD_LOGIN_AGAIN")) {
    return new ApiError("reauth-required", "Sign in again to continue.", details);
  }
  if (normalized.includes("FEDERATED_USER_ID_ALREADY_LINKED")) {
    return new ApiError("credential-already-in-use", "This sign-in method belongs to another account.", details);
  }
  if (normalized.includes("EMAIL_ALREADY_IN_USE") || normalized.includes("ACCOUNT_EXISTS_WITH_DIFFERENT_CREDENTIAL")) {
    return new ApiError("email-exists", "An account with this email already exists.", details);
  }
  if (normalized.includes("INVALID_IDP_RESPONSE") || normalized.includes("INVALID_ID_TOKEN")) {
    return new ApiError("invalid-credentials", "The identity provider rejected this credential.", details);
  }
  if (normalized.includes("INVALID_EMAIL") || normalized.includes("INVALID_EMAIL_ADDRESS")) {
    return new ApiError("invalid-argument", "The email address was rejected by the identity service.", details);
  }
  if (normalized.includes("WEAK_PASSWORD") || normalized.includes("MISSING_PASSWORD")) {
    return new ApiError("invalid-argument", "The password was rejected by the identity service.", details);
  }
  if (normalized.includes("TOKEN_EXPIRED") || normalized.includes("INVALID_REFRESH_TOKEN")) {
    return new ApiError("unauthenticated", "The session is no longer valid.", details);
  }
  if (normalized.includes("MISSING_REFRESH_TOKEN") || normalized.includes("INVALID_GRANT")) {
    return new ApiError("unauthenticated", "The session is no longer valid.", details);
  }
  // API key / provider configuration problems are permission problems, never a
  // malformed user request. Surfacing them as 400 hid this layer during
  // deployment testing.
  if (
    normalized.includes("API_KEY_SERVICE_BLOCKED") ||
    normalized.includes("API_KEY_IP_ADDRESS_BLOCKED") ||
    normalized.includes("API_KEY_HTTP_REFERRER_BLOCKED") ||
    normalized.includes("API_KEY_IOS_APP_BLOCKED") ||
    normalized.includes("API_KEY_ANDROID_APP_BLOCKED") ||
    normalized.includes("API KEY NOT VALID") ||
    normalized.includes("API_KEY_INVALID") ||
    normalized.includes("PERMISSION_DENIED")
  ) {
    return new ApiError(
      "permission-denied",
      "The server API key is not allowed for this request. Allow both Identity Toolkit API and Token Service API, and remove incompatible application restrictions.",
      details
    );
  }
  if (normalized.includes("OPERATION_NOT_ALLOWED") || normalized.includes("CONFIGURATION_NOT_FOUND")) {
    return new ApiError(
      "permission-denied",
      "This sign-in provider is not enabled for the Firebase project.",
      details
    );
  }
  if (normalized.includes("TOO_MANY_ATTEMPTS") || normalized.includes("QUOTA_EXCEEDED")) {
    return new ApiError("rate-limited", "Too many attempts. Try again shortly.", details);
  }
  if (status === 429) {
    return new ApiError("rate-limited", "Too many attempts. Try again shortly.", details);
  }
  if (status >= 500) {
    return new ApiError("upstream-unavailable", "The identity service is temporarily unavailable.", details);
  }
  return new ApiError("invalid-argument", "The identity service rejected the request.", details);
}

/** Pulls the first token-style error code out of an upstream message. */
export function extractUpstreamCode(message: string): string | null {
  const parenthesized = /\(([A-Z][A-Z0-9_]{3,})\)/.exec(message);
  if (parenthesized?.[1] !== undefined) return parenthesized[1];
  const first = message.trim().split(/[\s:]+/)[0];
  if (first !== undefined && /^[A-Z][A-Z0-9_]{3,}$/.test(first)) return first;
  return null;
}
