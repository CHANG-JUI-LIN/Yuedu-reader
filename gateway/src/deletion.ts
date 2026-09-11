import {FieldValue, type CollectionReference} from "firebase-admin/firestore";

import type {GatewayContext} from "./context.js";
import {ApiError} from "./errors.js";
import {revokeAppleAuthorizationCode} from "./identityToolkit.js";
import {avatarObjectPath} from "./policy.js";

/** Collections under `users/{uid}` that the client app owns. */
export const USER_SUBCOLLECTIONS = [
  "books",
  "bookSources",
  "replaceRules",
  "rssSources",
  "rssFolders",
  "rssArticleStatuses",
  "readingPositions",
];

export type DeletionStage =
  | "subscriptions"
  | "userData"
  | "avatar"
  | "appleRevocation"
  | "authUser";

export interface DeletionJob {
  uid: string;
  status: "pending" | "completed";
  stages: Partial<Record<DeletionStage, "done" | "failed">>;
  lastError?: {stage: DeletionStage; message: string};
}

/**
 * Deletes the account in the only order that cannot strand data: server-owned
 * subscription rows, Firestore user documents (owner-rule protected), avatar,
 * Apple token revocation, and the Auth user last. Every earlier stage is
 * idempotent, so a failed run can be retried with a fresh recent-auth check.
 *
 * The job document is written before the first destructive step and updated
 * after each stage, so a partial failure is diagnosable and resumable instead
 * of guessed at.
 */
export async function runAccountDeletion(
  context: GatewayContext,
  uid: string,
  appleAuthorizationCode: string | null,
  idTokenForAppleRevoke: string
): Promise<DeletionJob> {
  const jobReference = context.firestore.collection("accountDeletionJobs").doc(uid);
  await jobReference.set(
    {
      uid,
      status: "pending",
      stages: {},
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    },
    {merge: true}
  );

  const mark = async (stage: DeletionStage, failed: boolean, message?: string): Promise<void> => {
    await jobReference.set(
      {
        [`stages.${stage}`]: failed ? "failed" : "done",
        ...(failed ? {lastError: {stage, message: message ?? "unknown error"}} : {}),
        updatedAt: FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
  };

  // 1. Server-owned subscription bookkeeping.
  try {
    await context.callables.call("deleteSubscriptionAccountData", uid, {});
    await mark("subscriptions", false);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    await mark("subscriptions", true, message);
    throw new ApiError("cleanup-failed", "Subscription data could not be removed. Retry the deletion.", {
      stage: "subscriptions",
    });
  }

  // 2. Firestore profile and per-user collections.
  try {
    const userReference = context.firestore.collection("users").doc(uid);
    for (const collection of USER_SUBCOLLECTIONS) {
      await deleteCollection(context, userReference.collection(collection));
    }
    await userReference.delete();
    await mark("userData", false);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    await mark("userData", true, message);
    throw new ApiError("cleanup-failed", "Account data could not be removed. Retry the deletion.", {
      stage: "userData",
    });
  }

  // 3. Avatar object.
  try {
    await context.storage.bucket().file(avatarObjectPath(uid)).delete({ignoreNotFound: true});
    await mark("avatar", false);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    await mark("avatar", true, message);
    throw new ApiError("cleanup-failed", "The avatar could not be removed. Retry the deletion.", {
      stage: "avatar",
    });
  }

  // 4. Apple token revocation, only when the client supplied an Apple auth code.
  if (appleAuthorizationCode !== null && appleAuthorizationCode !== "") {
    try {
      await revokeAppleAuthorizationCode(
        {apiKey: context.config.apiKey, upstreamTimeoutMs: context.config.upstreamTimeoutMs},
        idTokenForAppleRevoke,
        appleAuthorizationCode
      );
      await mark("appleRevocation", false);
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown error";
      await mark("appleRevocation", true, message);
      throw new ApiError("apple-revoke-failed", "Apple access could not be revoked. Retry the deletion.", {
        stage: "appleRevocation",
      });
    }
  }

  // 5. The Auth user goes last. Once this succeeds the data above is gone.
  try {
    await context.auth.deleteUser(uid);
    await mark("authUser", false);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    await mark("authUser", true, message);
    throw new ApiError("cleanup-failed", "The account could not be deleted. Try again.", {
      stage: "authUser",
    });
  }

  await jobReference.set(
    {status: "completed", updatedAt: FieldValue.serverTimestamp()},
    {merge: true}
  );
  return {uid, status: "completed", stages: {
    subscriptions: "done",
    userData: "done",
    avatar: "done",
    ...(appleAuthorizationCode !== null && appleAuthorizationCode !== "" ?
      {appleRevocation: "done" as const} :
      {}),
    authUser: "done",
  }};
}

async function deleteCollection(
  context: GatewayContext,
  collection: CollectionReference
): Promise<void> {
  const snapshot = await collection.limit(400).get();
  if (snapshot.empty) return;
  const batch = context.firestore.batch();
  for (const document of snapshot.docs) {
    batch.delete(document.ref);
  }
  await batch.commit();
  if (snapshot.size === 400) {
    await deleteCollection(context, collection);
  }
}
