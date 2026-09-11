import {ApiError} from "./errors.js";

/**
 * Pure policy helpers. They are intentionally free of Express and Firebase so
 * the security-relevant rules can be unit-tested without credentials.
 */

// MARK: - Recent authentication

/**
 * Sensitive operations (link, unlink, account deletion) require a fresh
 * credential, not merely an unexpired ID token. We read `auth_time` from the
 * verified token and refuse anything older than the window. The client
 * re-authenticates through the gateway, which yields a token with a new
 * `auth_time`; nothing is trusted from a request body.
 */
export const RECENT_AUTH_MAX_AGE_SECONDS = 10 * 60;

export function recentAuthSatisfied(
  authTimeSeconds: number | undefined,
  nowSeconds: number,
  maxAgeSeconds: number = RECENT_AUTH_MAX_AGE_SECONDS
): boolean {
  if (authTimeSeconds === undefined || !Number.isFinite(authTimeSeconds)) return false;
  const age = nowSeconds - authTimeSeconds;
  // Clock skew must not make a fresh token look stale, and a token from the
  // future must not look fresh forever.
  return age >= -60 && age <= maxAgeSeconds;
}

export function requireRecentAuth(authTimeSeconds: number | undefined, nowSeconds: number): void {
  if (!recentAuthSatisfied(authTimeSeconds, nowSeconds)) {
    throw new ApiError("reauth-required", "Sign in again before continuing.");
  }
}

// MARK: - Profile whitelist

export const PROFILE_PREFERENCE_KEYS = [
  "readerFontSize",
  "theme",
  "lineHeightMultiple",
  "letterSpacing",
  "paragraphSpacingMultiplier",
  "pageMarginH",
  "pageMarginV",
  "footerBottomPadding",
  "footerTextGap",
  "pageTurnStyle",
  "readerWritingMode",
  "textConversion",
  "scrollMode",
  "readerHeaderVisible",
  "readerHeaderTopPadding",
  "readerHeaderTextGap",
  "readerHeaderFieldPositions",
  "readerTextColorOverrides",
] as const;

const PROFILE_NUMBER_KEYS: ReadonlySet<string> = new Set([
  "readerFontSize",
  "lineHeightMultiple",
  "letterSpacing",
  "paragraphSpacingMultiplier",
  "pageMarginH",
  "pageMarginV",
  "footerBottomPadding",
  "footerTextGap",
  "readerHeaderTopPadding",
  "readerHeaderTextGap",
]);

const PROFILE_BOOLEAN_KEYS: ReadonlySet<string> = new Set([
  "scrollMode",
  "readerHeaderVisible",
]);

const PROFILE_STRING_KEYS: ReadonlySet<string> = new Set([
  "theme",
  "pageTurnStyle",
  "readerWritingMode",
  "textConversion",
]);

/** Fields a client may never set through the profile endpoint. */
export const PROFILE_FORBIDDEN_KEYS = [
  "uid",
  "email",
  "provider",
  "createdAt",
  "updatedAt",
  "photoURL",
  "isProActive",
  "isAdmin",
  "verified",
  "subscription",
  "subscriptionTier",
  "role",
] as const;

export interface SanitizedProfilePatch {
  displayName?: string;
  preferences?: Record<string, unknown>;
}

export function sanitizeProfilePatch(input: unknown): SanitizedProfilePatch {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new ApiError("invalid-argument", "Profile payload must be an object.");
  }
  const body = input as Record<string, unknown>;
  for (const forbidden of PROFILE_FORBIDDEN_KEYS) {
    if (forbidden in body) {
      throw new ApiError("invalid-argument", `Field "${forbidden}" cannot be set by the client.`);
    }
  }
  const patch: SanitizedProfilePatch = {};

  if ("displayName" in body) {
    const value = body.displayName;
    if (typeof value !== "string") {
      throw new ApiError("invalid-argument", "displayName must be a string.");
    }
    const trimmed = value.trim();
    if (trimmed.length === 0 || trimmed.length > 80) {
      throw new ApiError("invalid-argument", "displayName must be 1-80 characters.");
    }
    patch.displayName = trimmed;
  }

  if ("preferences" in body) {
    patch.preferences = sanitizePreferences(body.preferences);
  }

  if (Object.keys(patch).length === 0) {
    throw new ApiError("invalid-argument", "No supported profile fields were provided.");
  }
  return patch;
}

function sanitizePreferences(input: unknown): Record<string, unknown> {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new ApiError("invalid-argument", "preferences must be an object.");
  }
  const source = input as Record<string, unknown>;
  const allowed = new Set<string>(PROFILE_PREFERENCE_KEYS);
  const clean: Record<string, unknown> = {};

  for (const [key, value] of Object.entries(source)) {
    if (!allowed.has(key)) continue; // older/newer clients: drop unknown keys on purpose
    if (PROFILE_NUMBER_KEYS.has(key)) {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 10_000) {
        throw new ApiError("invalid-argument", `preferences.${key} is out of range.`);
      }
      clean[key] = value;
    } else if (PROFILE_BOOLEAN_KEYS.has(key)) {
      if (typeof value !== "boolean") {
        throw new ApiError("invalid-argument", `preferences.${key} must be a boolean.`);
      }
      clean[key] = value;
    } else if (PROFILE_STRING_KEYS.has(key)) {
      if (typeof value !== "string" || value.length > 120) {
        throw new ApiError("invalid-argument", `preferences.${key} must be a short string.`);
      }
      clean[key] = value;
    } else if (key === "readerHeaderFieldPositions") {
      clean[key] = sanitizeStringMap(value, 16, 120);
    } else if (key === "readerTextColorOverrides") {
      clean[key] = sanitizeUInt32Map(value, 16);
    }
  }
  return clean;
}

function sanitizeStringMap(input: unknown, maxEntries: number, maxValueLength: number): Record<string, string> {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new ApiError("invalid-argument", "Expected a string map.");
  }
  const entries = Object.entries(input as Record<string, unknown>);
  if (entries.length > maxEntries) {
    throw new ApiError("invalid-argument", "Map has too many entries.");
  }
  const clean: Record<string, string> = {};
  for (const [key, value] of entries) {
    if (key.length > 64 || typeof value !== "string" || value.length > maxValueLength) {
      throw new ApiError("invalid-argument", "Invalid map entry.");
    }
    clean[key] = value;
  }
  return clean;
}

function sanitizeUInt32Map(input: unknown, maxEntries: number): Record<string, number> {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new ApiError("invalid-argument", "Expected a color map.");
  }
  const entries = Object.entries(input as Record<string, unknown>);
  if (entries.length > maxEntries) {
    throw new ApiError("invalid-argument", "Map has too many entries.");
  }
  const clean: Record<string, number> = {};
  for (const [key, value] of entries) {
    if (key.length > 64 || typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 0xFFFFFFFF) {
      throw new ApiError("invalid-argument", "Invalid color value.");
    }
    clean[key] = value;
  }
  return clean;
}

// MARK: - Entitlement selection

export type SubscriptionEnvironment = "production" | "sandbox";

export interface SelectedEntitlement {
  isProActive: boolean;
  productIds: string[] | null;
  expiresAtMilliseconds: number | null;
}

/**
 * `entitlements/{uid}` stores both StoreKit environments side by side. The
 * client names which build it is, and we read only that half — reading
 * `isProActive` unconditionally is exactly the leak that let a free TestFlight
 * purchase unlock the App Store build.
 */
export function selectEntitlement(
  data: Record<string, unknown>,
  environment: SubscriptionEnvironment
): SelectedEntitlement {
  const fields = environment === "sandbox" ?
    {isActive: "sandboxIsProActive", productIds: "sandboxProductIds", expiresAt: "sandboxExpiresAt"} :
    {isActive: "isProActive", productIds: "productIds", expiresAt: "expiresAt"};

  const rawExpires = data[fields.expiresAt] as {toMillis?: () => number} | null | undefined;
  const expiresAt = rawExpires !== null && rawExpires !== undefined && typeof rawExpires.toMillis === "function" ?
    rawExpires.toMillis() :
    null;
  const productIds = Array.isArray(data[fields.productIds]) ?
    (data[fields.productIds] as unknown[]).filter((value): value is string => typeof value === "string") :
    null;
  return {
    isProActive: data[fields.isActive] === true,
    productIds,
    expiresAtMilliseconds: expiresAt,
  };
}

// MARK: - Input validation

const EMAIL_PATTERN = /^[^\s@/]+@[^\s@/]+\.[^\s@/]+$/;

export function requireEmail(value: unknown, maxLength = 254): string {
  if (typeof value !== "string") {
    throw new ApiError("invalid-argument", "A valid email address is required.");
  }
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > maxLength || !EMAIL_PATTERN.test(trimmed)) {
    throw new ApiError("invalid-argument", "A valid email address is required.");
  }
  return trimmed;
}

export function requirePassword(value: unknown): string {
  if (typeof value !== "string" || value.length < 6 || value.length > 4096) {
    throw new ApiError("invalid-argument", "Password must be at least 6 characters.");
  }
  return value;
}

export function requireShortString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new ApiError("invalid-argument", `Invalid ${field}.`);
  }
  return value;
}

export function requireProvider(value: unknown): "apple" | "google" {
  if (value !== "apple" && value !== "google") {
    throw new ApiError("invalid-argument", "Unsupported identity provider.");
  }
  return value;
}

/** Provider IDs Firebase uses, as accepted for unlink. */
export const UNLINKABLE_PROVIDER_IDS = ["password", "apple.com", "google.com"] as const;

export function requireProviderId(value: unknown): string {
  if (typeof value !== "string" || !(UNLINKABLE_PROVIDER_IDS as readonly string[]).includes(value)) {
    throw new ApiError("invalid-argument", "Unsupported provider id.");
  }
  return value;
}

export function avatarObjectPath(uid: string): string {
  // uid comes from a verified token; the pattern check is defence in depth
  // against ever building a path from an unverified value.
  if (!/^[A-Za-z0-9]{1,128}$/.test(uid)) {
    throw new ApiError("invalid-argument", "Invalid account identifier.");
  }
  return `avatars/${uid}.jpg`;
}
