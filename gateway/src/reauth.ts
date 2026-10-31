import type {GatewayContext} from "./context.js";
import {ApiError} from "./errors.js";
import {signInWithIdp, signInWithPassword, type IdentitySession} from "./identityToolkit.js";
import {requirePassword, requireShortString} from "./policy.js";

export interface VerifiedReauthentication {
  /** A session for the same uid with a fresh `auth_time`. */
  session: IdentitySession;
  /** Present only for Apple, and only when the client sent one: deletion revokes it. */
  appleAuthorizationCode: string | null;
}

/**
 * Re-verifies a real credential for the signed-in account — never an
 * unexpired token alone. Deletion and the recent-auth refresh before linking
 * share this one path.
 *
 * The credential must be one of the account's own sign-in methods. A federated
 * credential for some other Apple or Google account is refused before it reaches
 * Firebase, because `signInWithIdp` creates an account for an unknown identity:
 * the earlier client re-verified a link with the identity being linked, and the
 * user ended up signed into a brand-new empty account.
 */
export async function verifyReauthentication(
  context: GatewayContext,
  uid: string,
  reauthBody: unknown
): Promise<VerifiedReauthentication> {
  const toolkit = {apiKey: context.config.apiKey, upstreamTimeoutMs: context.config.upstreamTimeoutMs};
  const reauth = requireObject(reauthBody);
  const record = await context.auth.getUser(uid);
  const linkedSubject = (providerId: string): string | null =>
    record.providerData.find((provider) => provider.providerId === providerId)?.uid ?? null;

  let session: IdentitySession;
  let appleAuthorizationCode: string | null = null;

  switch (reauth.provider) {
    case "password": {
      if (linkedSubject("password") === null) {
        throw new ApiError("invalid-argument", "Email sign-in is not linked to this account.");
      }
      const accountEmail = record.email;
      if (accountEmail === undefined || accountEmail === "") {
        throw new ApiError("invalid-argument", "This account has no email address.");
      }
      session = await signInWithPassword(toolkit, accountEmail, requirePassword(reauth.password));
      break;
    }
    case "apple": {
      const subject = linkedSubject("apple.com");
      if (subject === null) {
        throw new ApiError("invalid-argument", "Apple sign-in is not linked to this account.");
      }
      const idToken = requireShortString(reauth.idToken, "identity token", 20_000);
      const rawNonce = requireShortString(reauth.rawNonce, "nonce", 512);
      requireSameSubject(idToken, subject);
      session = (await signInWithIdp(toolkit, {provider: "apple", idToken, rawNonce})).session;
      if (typeof reauth.appleAuthorizationCode === "string" && reauth.appleAuthorizationCode !== "") {
        appleAuthorizationCode = requireShortString(reauth.appleAuthorizationCode, "authorization code", 8192);
      }
      break;
    }
    case "google": {
      const subject = linkedSubject("google.com");
      if (subject === null) {
        throw new ApiError("invalid-argument", "Google sign-in is not linked to this account.");
      }
      const idToken = requireShortString(reauth.idToken, "identity token", 20_000);
      const accessToken = typeof reauth.accessToken === "string" && reauth.accessToken !== "" ?
        requireShortString(reauth.accessToken, "access token", 20_000) :
        undefined;
      requireSameSubject(idToken, subject);
      session = (await signInWithIdp(toolkit, {
        provider: "google",
        idToken,
        ...(accessToken === undefined ? {} : {accessToken}),
      })).session;
      break;
    }
    default:
      throw new ApiError("invalid-argument", "A supported re-authentication provider is required.");
  }

  if (session.localId !== uid) {
    throw new ApiError("wrong-account", "The credential belongs to a different account.");
  }
  return {session, appleAuthorizationCode};
}

/**
 * Reads `sub` from a provider ID token WITHOUT verifying it. Used only to refuse
 * early; Firebase still verifies the signature of anything that is accepted.
 */
export function unverifiedTokenSubject(idToken: string): string | null {
  const payload = idToken.split(".")[1];
  if (payload === undefined || payload === "") return null;
  try {
    const claims: unknown = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    if (claims === null || typeof claims !== "object") return null;
    const subject = (claims as {sub?: unknown}).sub;
    return typeof subject === "string" && subject !== "" ? subject : null;
  } catch {
    return null;
  }
}

function requireSameSubject(idToken: string, linkedSubject: string): void {
  if (unverifiedTokenSubject(idToken) !== linkedSubject) {
    throw new ApiError("wrong-account", "Use the Apple or Google account already linked to this account.");
  }
}

export function requireObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError("invalid-argument", "Expected a JSON object.");
  }
  return value as Record<string, unknown>;
}
