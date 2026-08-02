import assert from "node:assert/strict";
import {generateKeyPairSync, verify} from "node:crypto";
import {describe, it} from "node:test";

import {
  AppStoreConnectClient,
  signedRequestHeaders,
  type AppStoreConnectCredentials,
} from "../src/appStoreConnect.js";

function testCredentials(): AppStoreConnectCredentials & {publicKeyPem: string} {
  const {publicKey, privateKey} = generateKeyPairSync("ec", {namedCurve: "P-256"});
  const privateKeyPem = privateKey.export({type: "pkcs8", format: "pem"});
  return {
    issuerId: "69a6de97-1f5a-47e3-e053-0823d01107a1",
    keyId: "TESTKEY1234",
    privateKeyBase64: Buffer.from(privateKeyPem).toString("base64"),
    publicKeyPem: publicKey.export({type: "spki", format: "pem"}),
  };
}

interface RecordedCall {
  method: string;
  url: string;
  body?: string;
}

function mockFetch(handler: (url: string, init?: RequestInit) => Response): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    return handler(String(input), init);
  }) as typeof fetch;
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {status, headers: {"Content-Type": "application/json"}});
}

describe("App Store Connect client", () => {
  it("signs an ES256 JWT with the expected claims and a verifiable signature", () => {
    const credentials = testCredentials();
    const headers = signedRequestHeaders(credentials);
    const token = headers.Authorization.replace("Bearer ", "");
    const [headerSegment, payloadSegment, signatureSegment] = token.split(".");

    const header = JSON.parse(Buffer.from(headerSegment, "base64url").toString("utf8"));
    assert.equal(header.alg, "ES256");
    assert.equal(header.kid, credentials.keyId);
    assert.equal(header.typ, "JWT");

    const payload = JSON.parse(Buffer.from(payloadSegment, "base64url").toString("utf8"));
    assert.equal(payload.iss, credentials.issuerId);
    assert.equal(payload.aud, "appstoreconnect-v1");
    assert.equal(payload.exp - payload.iat, 1200);

    const publicKey = Buffer.from(credentials.publicKeyPem);
    assert.equal(Buffer.from(signatureSegment, "base64url").length, 64);
    const valid = verify(
      "SHA256",
      Buffer.from(`${headerSegment}.${payloadSegment}`),
      {key: publicKey, dsaEncoding: "ieee-p1363"},
      Buffer.from(signatureSegment, "base64url")
    );
    assert.equal(valid, true);
  });

  it("finds an existing tester and group and links them", async () => {
    const calls: RecordedCall[] = [];
    const fetchImpl = mockFetch((url, init) => {
      const method = init?.method ?? "GET";
      calls.push({method, url, body: init?.body as string | undefined});
      if (url.includes("/betaTesters?filter[email]")) {
        return jsonResponse({data: [{id: "tester-1"}]});
      }
      if (url.includes("/betaGroups?filter[app]")) {
        return jsonResponse({data: [{id: "group-1"}]});
      }
      if (url.endsWith("/relationships/betaGroups")) {
        return new Response(null, {status: 204});
      }
      throw new Error(`unexpected ${method} ${url}`);
    });

    const client = new AppStoreConnectClient({
      credentials: testCredentials(),
      appId: "6772972358",
      groupName: "Yuedu 測試版",
      fetchImpl,
    });
    const result = await client.invite("user@example.com");

    assert.deepEqual(result, {
      testerId: "tester-1",
      groupId: "group-1",
      testerAlreadyExisted: true,
    });
    assert.deepEqual(calls.map((call) => call.method), ["GET", "GET", "POST"]);
    const relationshipBody = JSON.parse(calls[2].body!);
    assert.deepEqual(relationshipBody, {data: [{type: "betaGroups", id: "group-1"}]});
  });

  it("creates a missing tester and missing group before linking", async () => {
    const calls: RecordedCall[] = [];
    const fetchImpl = mockFetch((url, init) => {
      const method = init?.method ?? "GET";
      calls.push({method, url, body: init?.body as string | undefined});
      if (url.includes("/betaTesters?filter[email]")) {
        return jsonResponse({data: []});
      }
      if (url.endsWith("/betaTesters")) {
        return jsonResponse({data: {id: "tester-new"}}, 201);
      }
      if (url.includes("/betaGroups?filter[app]")) {
        return jsonResponse({data: []});
      }
      if (url.endsWith("/betaGroups")) {
        return jsonResponse({data: {id: "group-new"}}, 201);
      }
      throw new Error(`unexpected ${method} ${url}`);
    });

    const client = new AppStoreConnectClient({
      credentials: testCredentials(),
      appId: "6772972358",
      groupName: "Yuedu 測試版",
      fetchImpl,
    });
    const result = await client.invite("new@example.com");

    assert.deepEqual(result, {
      testerId: "tester-new",
      groupId: "group-new",
      testerAlreadyExisted: false,
    });
    assert.deepEqual(calls.map((call) => call.method), ["GET", "GET", "POST", "POST"]);
    const createGroupBody = JSON.parse(calls[2].body!);
    assert.equal(createGroupBody.data.type, "betaGroups");
    assert.equal(createGroupBody.data.attributes.name, "Yuedu 測試版");
    assert.equal(createGroupBody.data.relationships.app.data.id, "6772972358");
    const createTesterBody = JSON.parse(calls[3].body!);
    assert.deepEqual(createTesterBody, {
      data: {
        type: "betaTesters",
        attributes: {email: "new@example.com"},
        relationships: {betaGroups: {data: [{type: "betaGroups", id: "group-new"}]}},
      },
    });
  });

  it("throws with the API error detail on a failed response", async () => {
    const fetchImpl = mockFetch(() => {
      return jsonResponse({errors: [{detail: "bad request"}]}, 400);
    });
    const client = new AppStoreConnectClient({
      credentials: testCredentials(),
      appId: "6772972358",
      groupName: "Yuedu 測試版",
      fetchImpl,
    });
    await assert.rejects(
      () => client.invite("user@example.com"),
      /failed: 400/
    );
  });
});
