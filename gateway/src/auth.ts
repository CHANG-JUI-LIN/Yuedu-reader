import type {NextFunction, Request, Response} from "express";
import type {Auth, UserRecord} from "firebase-admin/auth";

import {ApiError, errorBody} from "./errors.js";

export interface AuthenticatedUser {
  uid: string;
  /** Seconds since epoch when the user actually signed in; drives recent-auth checks. */
  authTime: number;
  email: string | null;
  emailVerified: boolean;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      gatewayUser?: AuthenticatedUser;
    }
  }
}

/**
 * Verifies the Firebase ID token on every protected request.
 *
 * `checkRevoked: true` makes Firebase Console actions (disable account, revoke
 * refresh tokens) take effect on the very next Gateway call. That is one Auth
 * lookup per request; if it ever becomes a cost problem, a short-lived cache is
 * allowed only with a documented and tested maximum staleness. Not now.
 */
export function requireAuth(
  auth: Auth
): (request: Request, response: Response, next: NextFunction) => void {
  return (request, response, next) => {
    const header = request.header("authorization") ?? "";
    const match = /^Bearer\s+(.+)$/i.exec(header.trim());
    if (match === null || match[1] === undefined) {
      const error = new ApiError("unauthenticated", "Sign in to continue.");
      response.status(error.status).json(errorBody(error));
      return;
    }
    const token = match[1];
    auth
      .verifyIdToken(token, true)
      .then((decoded) => {
        request.gatewayUser = {
          uid: decoded.uid,
          authTime: typeof decoded.auth_time === "number" ? decoded.auth_time : 0,
          email: typeof decoded.email === "string" ? decoded.email : null,
          emailVerified: decoded.email_verified === true,
        };
        next();
      })
      .catch(() => {
        const error = new ApiError("unauthenticated", "The session is no longer valid.");
        response.status(error.status).json(errorBody(error));
      });
  };
}

export function authenticatedUser(request: Request): AuthenticatedUser {
  const user = request.gatewayUser;
  if (user === undefined) {
    throw new ApiError("unauthenticated", "Sign in to continue.");
  }
  return user;
}

export interface AccountUserPayload {
  uid: string;
  email: string | null;
  displayName: string | null;
  photoURL: string | null;
  emailVerified: boolean;
  providerIds: string[];
  disabled: boolean;
}

/** Server-authoritative account shape returned to the client (never token claims). */
export function accountUserPayload(record: UserRecord): AccountUserPayload {
  return {
    uid: record.uid,
    email: record.email ?? null,
    displayName: record.displayName ?? null,
    photoURL: record.photoURL ?? null,
    emailVerified: record.emailVerified,
    providerIds: record.providerData.map((provider) => provider.providerId),
    disabled: record.disabled,
  };
}
