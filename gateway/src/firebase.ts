import {applicationDefault, cert, getApps, initializeApp, type Credential} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import {getFirestore} from "firebase-admin/firestore";
import {getStorage} from "firebase-admin/storage";

import type {GatewayConfig} from "./config.js";

export interface FirebaseServices {
  auth: ReturnType<typeof getAuth>;
  firestore: ReturnType<typeof getFirestore>;
  storage: ReturnType<typeof getStorage>;
  /** The same credential the Admin app uses; validated at startup. */
  credential: Credential;
}

/**
 * Initialises the Admin SDK against the existing project. Credentials come from
 * either FIREBASE_SERVICE_ACCOUNT_JSON (inline/base64) or Application Default
 * Credentials. The credential is returned so startup can prove it resolves a
 * token before any request touches Firestore/Storage. No credential material is
 * ever logged or bundled into responses.
 */
export function initFirebase(config: GatewayConfig): FirebaseServices {
  let credential: Credential;
  if (getApps().length === 0) {
    if (config.serviceAccountJson !== null) {
      const parsed = JSON.parse(config.serviceAccountJson) as {
        project_id?: string;
        client_email?: string;
        private_key?: string;
      };
      if (
        parsed.project_id === undefined ||
        parsed.client_email === undefined ||
        parsed.private_key === undefined
      ) {
        throw new Error("FIREBASE_SERVICE_ACCOUNT_JSON is missing required fields");
      }
      if (parsed.project_id !== config.projectId) {
        throw new Error("Service account project does not match FIREBASE_PROJECT_ID");
      }
      credential = cert({
        projectId: parsed.project_id,
        clientEmail: parsed.client_email,
        privateKey: parsed.private_key,
      });
    } else {
      credential = applicationDefault();
    }
    initializeApp({
      credential,
      projectId: config.projectId,
      storageBucket: config.storageBucket,
    });
  } else {
    const app = getApps()[0];
    if (app === undefined) throw new Error("Firebase Admin failed to initialise");
    credential = app.options.credential ?? applicationDefault();
  }

  const app = getApps()[0];
  if (app === undefined) throw new Error("Firebase Admin failed to initialise");
  return {
    auth: getAuth(app),
    firestore: getFirestore(app),
    storage: getStorage(app),
    credential,
  };
}
