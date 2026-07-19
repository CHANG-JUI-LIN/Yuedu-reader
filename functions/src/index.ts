import {randomUUID} from "node:crypto";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";

import {
  Environment,
  JWSTransactionDecodedPayload,
  SignedDataVerifier,
} from "@apple/app-store-server-library";
import {getApps, initializeApp} from "firebase-admin/app";
import {FieldValue, Timestamp, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {onRequest} from "firebase-functions/v2/https";
import {logger} from "firebase-functions";

import {
  assertBindingOwner,
  assertTransactionCanBind,
  environmentName,
  transactionIsActive,
} from "./entitlementPolicy.js";

if (getApps().length === 0) {
  initializeApp();
}

const region = "asia-east1";
const bundleId = "com.zhangruilin.yuedureader";
const appAppleId = 6772972358;
const db = getFirestore();

const rootPem = readFileSync(resolve(__dirname, "../certs/apple-root-ca.pem"), "utf8");
const rootCertificates = rootPem
  .match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g)
  ?.map((certificate) => Buffer.from(certificate));

if (rootCertificates === undefined || rootCertificates.length === 0) {
  throw new Error("Apple root certificates are missing");
}

const verifiers = new Map<Environment, SignedDataVerifier>([
  [Environment.PRODUCTION, new SignedDataVerifier(
    rootCertificates,
    true,
    Environment.PRODUCTION,
    bundleId,
    appAppleId
  )],
  [Environment.SANDBOX, new SignedDataVerifier(
    rootCertificates,
    true,
    Environment.SANDBOX,
    bundleId
  )],
]);

interface AccountTokenDocument {
  token: string;
}

interface PurchaseBindingDocument {
  uid: string;
  appAccountToken: string;
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  active: boolean;
  environment: string;
  purchaseDate: Timestamp | null;
  expiresAt: Timestamp | null;
  revocationDate: Timestamp | null;
  updatedAt: FieldValue;
}

function requireUid(auth: {uid: string} | undefined): string {
  if (auth === undefined) {
    throw new HttpsError("unauthenticated", "Sign in before linking a purchase.");
  }
  return auth.uid;
}

function requireString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new HttpsError("invalid-argument", `Invalid ${field}.`);
  }
  return value;
}

function environmentFromJWS(jws: string): Environment {
  const components = jws.split(".");
  if (components.length !== 3) {
    throw new HttpsError("invalid-argument", "Invalid signed transaction.");
  }

  try {
    // This decode only selects the verifier. Trust begins after signature verification below.
    const payload = JSON.parse(Buffer.from(components[1], "base64url").toString("utf8"));
    const environment = environmentName(payload);
    if (environment === Environment.PRODUCTION) return Environment.PRODUCTION;
    if (environment === Environment.SANDBOX) return Environment.SANDBOX;
  } catch (error) {
    logger.warn("Unable to decode transaction environment", error);
  }
  throw new HttpsError("invalid-argument", "Unsupported transaction environment.");
}

async function verifyTransaction(jws: string): Promise<JWSTransactionDecodedPayload> {
  const environment = environmentFromJWS(jws);
  const verifier = verifiers.get(environment);
  if (verifier === undefined) {
    throw new HttpsError("failed-precondition", "Transaction verifier is unavailable.");
  }
  try {
    return await verifier.verifyAndDecodeTransaction(jws);
  } catch (error) {
    logger.warn("Apple transaction verification failed", error);
    throw new HttpsError("permission-denied", "Apple could not verify this purchase.");
  }
}

function timestamp(milliseconds: number | undefined): Timestamp | null {
  return milliseconds === undefined ? null : Timestamp.fromMillis(milliseconds);
}

function bindingData(
  transaction: JWSTransactionDecodedPayload,
  uid: string,
  accountToken: string
): PurchaseBindingDocument {
  const originalTransactionId = requireString(
    transaction.originalTransactionId,
    "original transaction identifier",
    128
  );
  const transactionId = requireString(transaction.transactionId, "transaction identifier", 128);
  const productId = requireString(transaction.productId, "product identifier", 160);

  return {
    uid,
    appAccountToken: accountToken,
    originalTransactionId,
    transactionId,
    productId,
    active: transactionIsActive(transaction),
    environment: String(transaction.environment),
    purchaseDate: timestamp(transaction.purchaseDate),
    expiresAt: timestamp(transaction.expiresDate),
    revocationDate: timestamp(transaction.revocationDate),
    updatedAt: FieldValue.serverTimestamp(),
  };
}

async function recomputeEntitlement(uid: string): Promise<Record<string, unknown>> {
  const snapshot = await db.collection("purchaseBindings").where("uid", "==", uid).get();
  const activeBindings = snapshot.docs
    .map((document) => document.data() as PurchaseBindingDocument)
    .filter((binding) => binding.active && (
      binding.expiresAt === null || binding.expiresAt.toMillis() > Date.now()
    ));
  const productIds = [...new Set(activeBindings.map((binding) => binding.productId))].sort();
  const expirationDates = activeBindings
    .map((binding) => binding.expiresAt?.toMillis())
    .filter((value): value is number => value !== undefined);
  const hasLifetime = activeBindings.some((binding) => binding.expiresAt === null);
  const data = {
    isProActive: activeBindings.length > 0,
    productIds,
    expiresAt: hasLifetime || expirationDates.length === 0 ? null : Timestamp.fromMillis(Math.max(...expirationDates)),
    updatedAt: FieldValue.serverTimestamp(),
  };
  await db.collection("entitlements").doc(uid).set(data);
  return {
    isProActive: data.isProActive,
    productIds,
    expiresAtMilliseconds: data.expiresAt?.toMillis() ?? null,
  };
}

async function stableAccountToken(uid: string): Promise<string> {
  const reference = db.collection("accountTokens").doc(uid);
  return db.runTransaction(async (firestoreTransaction) => {
    const snapshot = await firestoreTransaction.get(reference);
    const existing = snapshot.data() as AccountTokenDocument | undefined;
    if (existing?.token !== undefined) return existing.token;

    const token = randomUUID();
    firestoreTransaction.create(reference, {
      token,
      createdAt: FieldValue.serverTimestamp(),
    });
    return token;
  });
}

async function bindVerifiedTransaction(
  uid: string,
  accountToken: string,
  transaction: JWSTransactionDecodedPayload
): Promise<Record<string, unknown>> {
  try {
    assertTransactionCanBind(transaction, accountToken);
  } catch (error) {
    throw new HttpsError("failed-precondition", (error as Error).message);
  }

  const data = bindingData(transaction, uid, accountToken);
  const reference = db.collection("purchaseBindings").doc(data.originalTransactionId);
  await db.runTransaction(async (firestoreTransaction) => {
    const snapshot = await firestoreTransaction.get(reference);
    try {
      assertBindingOwner(snapshot.data()?.uid, uid);
    } catch (error) {
      throw new HttpsError("already-exists", (error as Error).message);
    }
    firestoreTransaction.set(reference, data, {merge: true});
  });
  return recomputeEntitlement(uid);
}

export const getSubscriptionAccountToken = onCall({region}, async (request) => {
  const uid = requireUid(request.auth);
  return {token: await stableAccountToken(uid)};
});

export const bindSubscriptionPurchase = onCall({region}, async (request) => {
  const uid = requireUid(request.auth);
  const signedTransaction = requireString(request.data?.signedTransaction, "signed transaction", 100_000);
  const accountToken = await stableAccountToken(uid);
  const transaction = await verifyTransaction(signedTransaction);
  return bindVerifiedTransaction(uid, accountToken, transaction);
});

export const deleteSubscriptionAccountData = onCall({region}, async (request) => {
  const uid = requireUid(request.auth);
  const bindings = await db.collection("purchaseBindings").where("uid", "==", uid).get();
  const batch = db.batch();
  bindings.docs.forEach((document) => batch.delete(document.ref));
  batch.delete(db.collection("entitlements").doc(uid));
  batch.delete(db.collection("accountTokens").doc(uid));
  await batch.commit();
  return {deleted: true};
});

export const appStoreServerNotifications = onRequest({region}, async (request, response) => {
  if (request.method !== "POST") {
    response.sendStatus(405);
    return;
  }

  try {
    const signedPayload = requireString(request.body?.signedPayload, "signed payload", 200_000);
    const environment = environmentFromJWS(signedPayload);
    const verifier = verifiers.get(environment);
    if (verifier === undefined) throw new Error("Missing verifier");
    const notification = await verifier.verifyAndDecodeNotification(signedPayload);
    const signedTransaction = notification.data?.signedTransactionInfo;
    if (signedTransaction === undefined) {
      response.sendStatus(204);
      return;
    }

    const transaction = await verifier.verifyAndDecodeTransaction(signedTransaction);
    const originalTransactionId = transaction.originalTransactionId;
    if (originalTransactionId === undefined) {
      response.sendStatus(204);
      return;
    }
    const reference = db.collection("purchaseBindings").doc(originalTransactionId);
    const snapshot = await reference.get();
    const existing = snapshot.data() as PurchaseBindingDocument | undefined;
    if (existing === undefined) {
      response.sendStatus(204);
      return;
    }

    await reference.set(bindingData(transaction, existing.uid, existing.appAccountToken), {merge: true});
    await recomputeEntitlement(existing.uid);
    response.sendStatus(204);
  } catch (error) {
    logger.error("App Store notification processing failed", error);
    response.sendStatus(400);
  }
});
