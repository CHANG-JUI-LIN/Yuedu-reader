import {defineSecret} from "firebase-functions/params";

// The App Store Connect API key, shared by every function that calls the API: the
// TestFlight invite flow (index.ts) and the triage inbox's Apple side (appleTriage.ts).
export const appStoreIssuerIdSecret = defineSecret("APP_STORE_CONNECT_ISSUER_ID");
export const appStoreKeyIdSecret = defineSecret("APP_STORE_CONNECT_KEY_ID");
export const appStorePrivateKeySecret = defineSecret("APP_STORE_CONNECT_PRIVATE_KEY");
export const appStoreKeySecrets = [appStoreIssuerIdSecret, appStoreKeyIdSecret, appStorePrivateKeySecret];

/// 閱讀's Apple ID in App Store Connect.
export const appAppleId = 6772972358;
