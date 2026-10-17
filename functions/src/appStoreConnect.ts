import {createPrivateKey, createSign} from "node:crypto";

const apiBaseUrl = "https://api.appstoreconnect.apple.com/v1";
const tokenLifetimeSeconds = 20 * 60;

export interface AppStoreConnectCredentials {
  issuerId: string;
  keyId: string;
  /** PEM contents of the .p8 key, base64-encoded (survives env-var storage). */
  privateKeyBase64: string;
}

export interface AppStoreConnectClientOptions {
  credentials: AppStoreConnectCredentials;
  appId: string;
  /** The TestFlight group `invite` adds testers to; only the invite flow needs it. */
  groupName?: string;
  fetchImpl?: typeof fetch;
}

export interface AppStoreConnectInviteResult {
  testerId: string;
  groupId: string;
  /** True when Apple already had this address as a beta tester. */
  testerAlreadyExisted: boolean;
}

/**
 * ES256 JWT signed with the App Store Connect API key, per Apple's
 * authentication requirements (alg=ES256, kid=key id, iss=issuer id,
 * aud=appstoreconnect-v1, exp ≤ now + 20 minutes).
 */
export function signedRequestHeaders(
  credentials: AppStoreConnectCredentials
): Record<string, string> {
  const now = Math.floor(Date.now() / 1000);
  const header = {alg: "ES256", kid: credentials.keyId, typ: "JWT"};
  const payload = {
    iss: credentials.issuerId,
    iat: now,
    exp: now + tokenLifetimeSeconds,
    aud: "appstoreconnect-v1",
  };
  const signingInput = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(payload))}`;
  const privateKey = createPrivateKey(Buffer.from(credentials.privateKeyBase64, "base64"));
  // App Store Connect expects the JOSE/IEEE-P1363 form (r || s), not the
  // ASN.1 DER form Node uses by default for ECDSA signatures.
  const signature = createSign("SHA256").update(signingInput).sign({
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return {Authorization: `Bearer ${signingInput}.${base64Url(signature)}`};
}

function base64Url(data: string | Buffer): string {
  return Buffer.from(data).toString("base64url");
}

/**
 * Thin client for the App Store Connect API. The TestFlight tester-invite flow:
 * find-or-create the beta tester, find-or-create the beta group, and link the
 * tester to the group (Apple sends the invite email automatically once a group
 * build is in external testing). The triage inbox reads through `getJSON`.
 */
export class AppStoreConnectClient {
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly options: AppStoreConnectClientOptions) {
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  /** Idempotent: re-inviting an existing tester/group is a no-op link. */
  async invite(email: string): Promise<AppStoreConnectInviteResult> {
    const groupName = this.options.groupName;
    if (groupName === undefined) throw new Error("invite needs a TestFlight group name");
    const existingTesterId = await this.findBetaTesterByEmail(email);
    const groupId = await this.findBetaGroupByName(groupName)
      ?? await this.createBetaGroup(groupName);

    // Apple requires a betaGroups or builds relationship when creating a
    // tester. Existing testers can be linked after the lookup, but new ones
    // must receive the group relationship in the create request itself.
    if (existingTesterId !== null) {
      await this.addTesterToGroup(existingTesterId, groupId);
      return {testerId: existingTesterId, groupId, testerAlreadyExisted: true};
    }

    const testerId = await this.createBetaTester(email, groupId);
    return {testerId, groupId, testerAlreadyExisted: false};
  }

  async findBetaTesterByEmail(email: string): Promise<string | null> {
    const response = await this.request(
      `/betaTesters?filter[email]=${encodeURIComponent(email)}`
    );
    const payload = await response.json() as {data?: Array<{id: string}>};
    return payload.data?.[0]?.id ?? null;
  }

  /** Remove access to this app, including other groups/builds, not other apps. */
  async revokeAppAccess(email: string): Promise<void> {
    const testerId = await this.findBetaTesterByEmail(email);
    if (testerId === null) return;
    await this.request(`/betaTesters/${testerId}/relationships/apps`, {
      method: "DELETE",
      body: JSON.stringify({data: [{type: "apps", id: this.options.appId}]}),
    });
  }

  async createBetaTester(email: string, groupId: string): Promise<string> {
    const response = await this.request("/betaTesters", {
      method: "POST",
      body: JSON.stringify({
        data: {
          type: "betaTesters",
          attributes: {email},
          relationships: {betaGroups: {data: [{type: "betaGroups", id: groupId}]}},
        },
      }),
    });
    const payload = await response.json() as {data: {id: string}};
    return payload.data.id;
  }

  async findBetaGroupByName(name: string): Promise<string | null> {
    const response = await this.request(
      `/betaGroups?filter[app]=${this.options.appId}&filter[name]=${encodeURIComponent(name)}`
    );
    const payload = await response.json() as {data?: Array<{id: string}>};
    return payload.data?.[0]?.id ?? null;
  }

  async createBetaGroup(name: string): Promise<string> {
    const response = await this.request("/betaGroups", {
      method: "POST",
      body: JSON.stringify({
        data: {
          type: "betaGroups",
          attributes: {name},
          relationships: {app: {data: {type: "apps", id: this.options.appId}}},
        },
      }),
    });
    const payload = await response.json() as {data: {id: string}};
    return payload.data.id;
  }

  async addTesterToGroup(testerId: string, groupId: string): Promise<void> {
    await this.request(`/betaTesters/${testerId}/relationships/betaGroups`, {
      method: "POST",
      body: JSON.stringify({data: [{type: "betaGroups", id: groupId}]}),
    });
  }

  /** A GET whose JSON body the caller types; `path` is relative to /v1. */
  async getJSON<T>(path: string): Promise<T> {
    const response = await this.request(path);
    return await response.json() as T;
  }

  /**
   * A GET for a resource that may legitimately not exist: 404 is `undefined`, every other
   * failure still throws. A TestFlight crash submission's `crashLog` is one — App Store
   * Connect answers 404 for a submission it holds no log for (AGT4StkW1MHoKzDbZNJd4So,
   * 2026-10-16: still 404 on redelivery five hours later), and the submission itself is
   * still worth filing.
   */
  async getJSONIfPresent<T>(path: string): Promise<T | undefined> {
    const response = await this.fetchImpl(`${apiBaseUrl}${path}`, {
      headers: {"Content-Type": "application/json", ...signedRequestHeaders(this.options.credentials)},
    });
    if (response.status === 404) return undefined;
    if (!response.ok) {
      throw new Error(`App Store Connect API GET ${path} failed: ${response.status} ${await response.text()}`);
    }
    return await response.json() as T;
  }

  private async request(path: string, init: RequestInit = {}): Promise<Response> {
    const response = await this.fetchImpl(`${apiBaseUrl}${path}`, {
      ...init,
      headers: {
        "Content-Type": "application/json",
        ...signedRequestHeaders(this.options.credentials),
        ...init.headers,
      },
    });
    if (!response.ok) {
      throw new Error(
        `App Store Connect API ${init.method ?? "GET"} ${path} failed: ${response.status} ${await response.text()}`
      );
    }
    return response;
  }
}
