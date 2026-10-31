import {Router} from "express";

import {accountUserPayload, authenticatedUser, requireAuth} from "../auth.js";
import type {GatewayContext} from "../context.js";
import {runAccountDeletion} from "../deletion.js";
import {ApiError, errorBody} from "../errors.js";
import {requireObject, verifyReauthentication} from "../reauth.js";

export function accountRouter(context: GatewayContext): Router {
  const router = Router();

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
      const {session, appleAuthorizationCode} = await verifyReauthentication(context, user.uid, body.reauth);
      const job = await runAccountDeletion(context, user.uid, appleAuthorizationCode, session.idToken);
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
