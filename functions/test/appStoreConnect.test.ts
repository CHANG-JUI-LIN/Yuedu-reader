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

  it("revokes all access to this app without deleting the tester from other apps", async () => {
    const calls: RecordedCall[] = [];
    const client = new AppStoreConnectClient({
      credentials: testCredentials(), appId: "6772972358", groupName: "beta",
      fetchImpl: mockFetch((url, init) => {
        calls.push({url, method: init?.method ?? "GET", body: init?.body as string | undefined});
        if (url.includes("?filter[email]")) return jsonResponse({data: [{id: "tester-1"}]});
        return new Response(null, {status: 204});
      }),
    });
    await client.revokeAppAccess("member@example.com");
    assert.equal(calls[1].url, "https://api.appstoreconnect.apple.com/v1/betaTesters/tester-1/relationships/apps");
    assert.equal(calls[1].method, "DELETE");
    assert.deepEqual(JSON.parse(calls[1].body!), {data: [{type: "apps", id: "6772972358"}]});
  });

  it("handles an already absent tester and reports failed removal", async () => {
    const options = {credentials: testCredentials(), appId: "6772972358", groupName: "beta"};
    let calls = 0;
    await new AppStoreConnectClient({...options, fetchImpl: mockFetch(() => {
      calls++;
      return jsonResponse({data: []});
    })}).revokeAppAccess("member@example.com");
    assert.equal(calls, 1);
    const client = new AppStoreConnectClient({...options, fetchImpl: mockFetch((url) => {
      if (url.includes("?filter[email]")) return jsonResponse({data: [{id: "tester-1"}]});
      return jsonResponse({errors: []}, 503);
    })});
    await assert.rejects(client.revokeAppAccess("member@example.com"), /failed: 503/);
  });

  it("reads a possibly absent resource as undefined on 404 only", async () => {
    const options = {credentials: testCredentials(), appId: "6772972358", groupName: "beta"};
    const absent = new AppStoreConnectClient({...options, fetchImpl: mockFetch(() =>
      jsonResponse({errors: [{status: "404", code: "NOT_FOUND"}]}, 404))});
    assert.equal(await absent.getJSONIfPresent("/betaFeedbackCrashSubmissions/x/crashLog"), undefined);

    const present = new AppStoreConnectClient({...options, fetchImpl: mockFetch(() =>
      jsonResponse({data: {attributes: {logText: "Thread 0 Crashed"}}}))});
    assert.deepEqual(
      await present.getJSONIfPresent("/betaFeedbackCrashSubmissions/x/crashLog"),
      {data: {attributes: {logText: "Thread 0 Crashed"}}}
    );

    const failing = new AppStoreConnectClient({...options, fetchImpl: mockFetch(() =>
      jsonResponse({errors: []}, 503))});
    await assert.rejects(failing.getJSONIfPresent("/betaFeedbackCrashSubmissions/x/crashLog"), /failed: 503/);
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
