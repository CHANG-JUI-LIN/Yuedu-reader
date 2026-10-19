import {createPrivateKey, sign, type KeyObject} from "node:crypto";
import {connect, type ClientHttp2Session} from "node:http2";

import {apnsHost, type PushDevice} from "./feedbackPushPolicy.js";

/// The app's bundle id: the APNs topic every alert goes to.
export const apnsTopic = "com.zhangruilin.yuedureader";

export interface APNsCredentials {
  teamId: string;
  keyId: string;
  /// The `.p8` file's contents (PEM, PKCS#8).
  privateKey: string;
}

export interface APNsResult {
  status: number;
  reason?: string;
}

/// Token-based APNs over HTTP/2 (https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
/// One connection per host for the life of the client; the provider token is reused for
/// its allowed hour and refreshed after 50 minutes (APNs refuses one refreshed more than
/// once every 20 minutes, and one older than an hour).
export class APNsClient {
  private readonly key: KeyObject;
  private token: {value: string; issuedAt: number} | null = null;
  private readonly sessions = new Map<string, ClientHttp2Session>();

  constructor(private readonly credentials: APNsCredentials) {
    this.key = createPrivateKey(credentials.privateKey);
  }

  async send(device: PushDevice, payload: Record<string, unknown>, collapseId: string): Promise<APNsResult> {
    const session = this.session(apnsHost(device.environment));
    const request = session.request({
      ":method": "POST",
      ":path": `/3/device/${device.token}`,
      "authorization": `bearer ${this.providerToken()}`,
      "apns-topic": apnsTopic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": collapseId.slice(0, 64),
      "content-type": "application/json",
    });
    request.end(JSON.stringify(payload));

    return new Promise((resolve, reject) => {
      let status = 0;
      const chunks: Buffer[] = [];
      request.on("response", (headers) => {
        status = Number(headers[":status"] ?? 0);
      });
      request.on("data", (chunk: Buffer) => chunks.push(chunk));
      request.on("error", reject);
      request.on("end", () => {
        if (status === 200) {
          resolve({status});
          return;
        }
        let reason: string | undefined;
        try {
          reason = (JSON.parse(Buffer.concat(chunks).toString("utf8")) as {reason?: string}).reason;
        } catch {
          reason = Buffer.concat(chunks).toString("utf8").slice(0, 200);
        }
        resolve({status, reason});
      });
    });
  }

  close(): void {
    for (const session of this.sessions.values()) session.close();
    this.sessions.clear();
  }

  private session(host: string): ClientHttp2Session {
    const existing = this.sessions.get(host);
    if (existing !== undefined && !existing.closed && !existing.destroyed) return existing;
    const session = connect(host);
    session.on("error", () => this.sessions.delete(host));
    session.on("close", () => this.sessions.delete(host));
    this.sessions.set(host, session);
    return session;
  }

  private providerToken(): string {
    const now = Math.floor(Date.now() / 1000);
    if (this.token !== null && now - this.token.issuedAt < 50 * 60) return this.token.value;
    const header = base64url(JSON.stringify({alg: "ES256", kid: this.credentials.keyId}));
    const claims = base64url(JSON.stringify({iss: this.credentials.teamId, iat: now}));
    const signature = sign("sha256", Buffer.from(`${header}.${claims}`), {key: this.key, dsaEncoding: "ieee-p1363"});
    const value = `${header}.${claims}.${base64url(signature)}`;
    this.token = {value, issuedAt: now};
    return value;
  }
}

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}
