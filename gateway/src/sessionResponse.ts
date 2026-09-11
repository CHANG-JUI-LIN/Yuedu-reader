import type {Auth} from "firebase-admin/auth";

import {accountUserPayload} from "./auth.js";
import type {IdentitySession, IdpSignInInput} from "./identityToolkit.js";

export interface SessionPayload {
  idToken: string;
  refreshToken: string;
  expiresIn: number;
  user: ReturnType<typeof accountUserPayload>;
}

export async function buildSessionPayload(auth: Auth, session: IdentitySession): Promise<SessionPayload> {
  const record = await auth.getUser(session.localId);
  return {
    idToken: session.idToken,
    refreshToken: session.refreshToken,
    expiresIn: session.expiresIn,
    user: accountUserPayload(record),
  };
}

/**
 * Apple only hands the name over on the very first authorization. The client
 * passes it through the IDP exchange; if Firebase did not persist it (empty
 * profile display name), we set it once on the Admin side. The client never
 * gets to overwrite an existing display name this way.
 */
export async function applyFirstAppleDisplayName(
  auth: Auth,
  uid: string,
  input: IdpSignInInput
): Promise<void> {
  if (input.provider !== "apple" || input.fullName === undefined) return;
  const formatted = [input.fullName.givenName, input.fullName.familyName]
    .filter((part): part is string => typeof part === "string" && part.trim() !== "")
    .join(" ")
    .trim();
  if (formatted === "") return;
  const record = await auth.getUser(uid);
  if ((record.displayName ?? "").trim() !== "") return;
  await auth.updateUser(uid, {displayName: formatted.slice(0, 80)});
}
