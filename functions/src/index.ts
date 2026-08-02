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
import {defineSecret} from "firebase-functions/params";

import {AppStoreConnectClient} from "./appStoreConnect.js";
import {
  assertBindingOwner,
  assertTransactionCanBind,
  bindingGrantsEntitlement,
  environmentName,
  transactionIsActive,
} from "./entitlementPolicy.js";
import {
  decideTestFlightProRequest,
  normalizeTestFlightEmail,
} from "./testflightRequestPolicy.js";

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

interface TestFlightRequestDocument {
  uid?: string;
  email: string;
  status: string;
  createdAt: FieldValue;
  updatedAt?: FieldValue;
}

interface TestFlightProRequestDocument {
  uid: string;
  email: string;
  status: string;
  createdAt: FieldValue;
  updatedAt?: FieldValue;
}

interface EntitlementDocument {
  isProActive?: boolean;
  expiresAt?: Timestamp | null;
}

const testFlightGroupNameSecret = defineSecret("APP_STORE_CONNECT_GROUP_NAME");
const appStoreIssuerIdSecret = defineSecret("APP_STORE_CONNECT_ISSUER_ID");
const appStoreKeyIdSecret = defineSecret("APP_STORE_CONNECT_KEY_ID");
const appStorePrivateKeySecret = defineSecret("APP_STORE_CONNECT_PRIVATE_KEY");
const appStoreConnectSecrets = [
  appStoreIssuerIdSecret,
  appStoreKeyIdSecret,
  appStorePrivateKeySecret,
  testFlightGroupNameSecret,
];
/// Beta group created automatically if the configured group does not exist.
const defaultTestFlightGroupName = "Yuedu 測試版";

function requireUid(
  auth: {uid: string} | undefined,
  message = "Sign in before linking a purchase."
): string {
  if (auth === undefined) {
    throw new HttpsError("unauthenticated", message);
  }
  return auth.uid;
}

async function requireActivePro(uid: string): Promise<void> {
  const snapshot = await db.collection("entitlements").doc(uid).get();
  const entitlement = snapshot.data() as EntitlementDocument | undefined;
  const expiresAt = entitlement?.expiresAt;
  const expired = expiresAt instanceof Timestamp && expiresAt.toMillis() <= Date.now();
  if (entitlement?.isProActive !== true || expired) {
    throw new HttpsError(
      "permission-denied",
      "An active Pro account is required to request TestFlight access."
    );
  }
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
    if (environment === Environment.XCODE || environment === Environment.LOCAL_TESTING) {
      // Local StoreKit Configuration transactions (Xcode scheme with a
      // .storekit file) are signed with local certificates and can never be
      // verified or bound. Real transactions only appear in TestFlight or
      // App Store builds, where the environment is Sandbox or Production.
      throw new HttpsError(
        "invalid-argument",
        "Local Xcode StoreKit configuration transactions cannot be bound. Test with TestFlight or the App Store sandbox."
      );
    }
  } catch (error) {
    if (error instanceof HttpsError) throw error;
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
  // Second line of defence behind `assertTransactionCanBind`: this also
  // neutralises the Sandbox bindings already written before that check existed,
  // so the stale TestFlight grants stop counting the moment this deploys — no
  // data migration needed to stop the leak.
  const activeBindings = snapshot.docs
    .map((document) => document.data() as PurchaseBindingDocument)
    .filter((binding) => bindingGrantsEntitlement(binding));
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

/// Adds the tester to the App Store Connect beta group so Apple sends the
/// invite email. Never throws: misconfiguration or API failure must not fail
/// the callable — the one-time request stays recorded in Firestore with a
/// "failed" status for the developer to resolve manually. The existing-tester
/// result is kept distinct so the client can explain that no new Apple invite
/// was created.
type TestFlightInviteStatus = "invited" | "alreadyInTestFlight" | "failed";

async function inviteTestFlightTester(email: string): Promise<TestFlightInviteStatus> {
  try {
    const client = new AppStoreConnectClient({
      credentials: {
        issuerId: appStoreIssuerIdSecret.value(),
        keyId: appStoreKeyIdSecret.value(),
        privateKeyBase64: appStorePrivateKeySecret.value(),
      },
      appId: String(appAppleId),
      groupName: testFlightGroupNameSecret.value() ?? defaultTestFlightGroupName,
    });
    const {testerId, groupId, testerAlreadyExisted} = await client.invite(email);
    logger.info(`TestFlight invite requested: email ${email} tester ${testerId} group ${groupId}`);
    return testerAlreadyExisted ? "alreadyInTestFlight" : "invited";
  } catch (error) {
    logger.error(`TestFlight invite failed for ${email}`, error);
    return "failed";
  }
}

export const requestTestFlightAccess = onCall(
  {region, secrets: appStoreConnectSecrets},
  async (request) => {
    const uid = requireUid(
      request.auth,
      "Sign in with a Pro account before requesting TestFlight access."
    );
    await requireActivePro(uid);

    const email = normalizeTestFlightEmail(request.data?.email);
    if (email === null) {
      throw new HttpsError("invalid-argument", "Invalid email address.");
    }

    // Claim both the Pro account's one-time slot and the normalized address in
    // one transaction. This prevents two concurrent requests from the same Pro
    // account (or two accounts using the same address) from both being invited.
    const reference = db.collection("testflightRequests").doc(email);
    const ownerReference = db.collection("testflightProRequests").doc(uid);
    const data: TestFlightRequestDocument = {
      uid,
      email,
      status: "pending",
      createdAt: FieldValue.serverTimestamp(),
    };
    const ownerData: TestFlightProRequestDocument = {
      uid,
      email,
      status: "pending",
      createdAt: FieldValue.serverTimestamp(),
    };
    const claim = await db.runTransaction(async (transaction) => {
      const ownerSnapshot = await transaction.get(ownerReference);
      const snapshot = await transaction.get(reference);
      const owner = ownerSnapshot.data() as TestFlightProRequestDocument | undefined;
      const existing = snapshot.data() as TestFlightRequestDocument | undefined;

      const ownerDecision = decideTestFlightProRequest(owner?.email, email);
      if (ownerDecision === "alreadySubmitted") {
        return {accepted: false, status: owner?.status ?? existing?.status ?? "pending"};
      }
      if (ownerDecision === "differentEmail") {
        throw new HttpsError(
          "already-exists",
          "Each Pro account can request TestFlight access only once."
        );
      }
      if (snapshot.exists) {
        return {accepted: false, status: existing?.status ?? "pending"};
      }
      transaction.create(ownerReference, ownerData);
      transaction.create(reference, data);
      return {accepted: true, status: "pending"};
    });
    if (!claim.accepted) {
      return {alreadySubmitted: true, status: claim.status};
    }

    const status = await inviteTestFlightTester(email);
    const update = {status, updatedAt: FieldValue.serverTimestamp()};
    const batch = db.batch();
    batch.update(reference, update);
    batch.update(ownerReference, update);
    await batch.commit();
    return {alreadySubmitted: false, status};
  }
);

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
