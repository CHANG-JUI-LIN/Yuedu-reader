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
 * Deletes the account in the only order that cannot strand data: Apple token
 * revocation first (it deletes nothing of ours, so a failure leaves the account
 * whole), then server-owned subscription rows, Firestore user documents
 * (owner-rule protected), avatar, and the Auth user last. Every stage is
 * idempotent, so a failed run can be retried with a fresh recent-auth check.
 *
 * Revocation used to run fourth. When it failed — every time, while it was sent
 * to a v1 URL that does not exist — users were left with their subscription
 * binding, profile and avatar deleted and the account itself still there.
 *
 * The job document is written before the first step and updated after each
 * stage, so a partial failure is diagnosable and resumable instead of guessed at.
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
    // `set` takes field names literally: a "stages.x" key became a top-level
    // field with a dot in its name and left `stages` empty. Nest the object.
    await jobReference.set(
      {
        stages: {[stage]: failed ? "failed" : "done"},
        ...(failed ? {lastError: {stage, message: message ?? "unknown error"}} : {}),
        updatedAt: FieldValue.serverTimestamp(),
      },
      {merge: true}
    );
  };

  // 1. Apple token revocation, only when the client supplied an Apple auth code.
  if (appleAuthorizationCode !== null && appleAuthorizationCode !== "") {
    try {
      await revokeAppleAuthorizationCode(
        {
          apiKey: context.config.apiKey,
          upstreamTimeoutMs: context.config.upstreamTimeoutMs,
          iosBundleId: context.config.iosBundleId,
        },
        idTokenForAppleRevoke,
        appleAuthorizationCode
      );
      await mark("appleRevocation", false);
    } catch (error) {
      const message = failureMessage(error);
      await mark("appleRevocation", true, message);
      throw new ApiError("apple-revoke-failed", "Apple access could not be revoked. Retry the deletion.", {
        stage: "appleRevocation",
      });
    }
  }

  // 2. Server-owned subscription bookkeeping.
  try {
    await context.callables.call("deleteSubscriptionAccountData", uid, {});
    await mark("subscriptions", false);
  } catch (error) {
    const message = failureMessage(error);
    await mark("subscriptions", true, message);
    throw new ApiError("cleanup-failed", "Subscription data could not be removed. Retry the deletion.", {
      stage: "subscriptions",
    });
  }

  // 3. Firestore profile and per-user collections.
  try {
    const userReference = context.firestore.collection("users").doc(uid);
    for (const collection of USER_SUBCOLLECTIONS) {
      await deleteCollection(context, userReference.collection(collection));
    }
    await userReference.delete();
    await mark("userData", false);
  } catch (error) {
    const message = failureMessage(error);
    await mark("userData", true, message);
    throw new ApiError("cleanup-failed", "Account data could not be removed. Retry the deletion.", {
      stage: "userData",
    });
  }

  // 4. Avatar object.
  try {
    await context.storage.bucket().file(avatarObjectPath(uid)).delete({ignoreNotFound: true});
    await mark("avatar", false);
  } catch (error) {
    const message = failureMessage(error);
    await mark("avatar", true, message);
    throw new ApiError("cleanup-failed", "The avatar could not be removed. Retry the deletion.", {
      stage: "avatar",
    });
  }

  // 5. The Auth user goes last. Once this succeeds the data above is gone.
  try {
    await context.auth.deleteUser(uid);
    await mark("authUser", false);
  } catch (error) {
    const message = failureMessage(error);
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

/**
 * Keeps the upstream status and code next to the message: the job only said
 * "The identity service rejected the request." while revocation hit a 404.
 */
function failureMessage(error: unknown): string {
  if (error instanceof ApiError) {
    const upstream = [error.details?.upstreamStatus, error.details?.upstream]
      .filter((part) => part !== undefined)
      .join(" ");
    return upstream === "" ? `${error.code}: ${error.message}` : `${error.code}: ${error.message} [${upstream}]`;
  }
  return error instanceof Error ? error.message : "unknown error";
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
