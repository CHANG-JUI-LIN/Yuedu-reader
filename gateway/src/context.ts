import type {Auth} from "firebase-admin/auth";
import type {Credential} from "firebase-admin/app";
import type {Firestore} from "firebase-admin/firestore";
import type {Storage} from "firebase-admin/storage";

import type {CallableCaller} from "./callableProxy.js";
import type {GatewayConfig} from "./config.js";

export interface GatewayContext {
  config: GatewayConfig;
  auth: Auth;
  firestore: Firestore;
  storage: Storage;
  credential: Credential;
  callables: CallableCaller;
  /**
   * True only after the Admin credential has produced an access token once.
   * Until then the data plane returns 503 and readiness reports degraded: the
   * Firestore client leaks a rejection (and throws from a timer) when it tries
   * to load missing Application Default Credentials, so we never let a request
   * reach it in that state.
   */
  credentialsReady: boolean;
}
