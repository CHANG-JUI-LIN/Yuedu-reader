import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  diagnosticItemId,
  diagnosticObservation,
  maxDetailLength,
  readEachBuild,
  parseWebhookEvent,
  signaturesWorthRecording,
  summarizeDiagnosticLogs,
  testFlightKind,
  testFlightObservation,
  verifyAppleSignature,
} from "../src/appleTriagePolicy.js";
import {telegramMessage} from "../src/triagePolicy.js";

describe("Apple triage policy", () => {
  it("accepts Apple's documented HMAC example and rejects anything else", () => {
    // From "Configuring and parsing App Store Connect API webhook notifications".
    const body = Buffer.from("Hello, World!");
    const header = "hmacsha256=7f062172b01cb00b53ca068614674a3d982a34062a0f5d37687d5e3377e54657";
    assert.equal(verifyAppleSignature(body, header, "This is my secret"), true);
    assert.equal(verifyAppleSignature(body, header, "another secret"), false);
    assert.equal(verifyAppleSignature(Buffer.from("Hello, World?"), header, "This is my secret"), false);
    assert.equal(verifyAppleSignature(body, undefined, "This is my secret"), false);
    assert.equal(verifyAppleSignature(body, "hmacsha256=00", "This is my secret"), false);
    assert.equal(verifyAppleSignature(body, header.replace("hmacsha256=", ""), "This is my secret"), false);
  });

  it("reads Apple's documented crash submission event", () => {
    const event = parseWebhookEvent(JSON.stringify({
      data: {
        type: "betaFeedbackCrashSubmissionCreated",
        id: "a4319bc8-ed16-460b-8de6-ba9734b55631",
        version: 1,
        attributes: {timestamp: "2025-05-16T20:53:20.729Z"},
        relationships: {instance: {data: {type: "betaFeedbackCrashSubmissions", id: "AK7UjG-qL5QxXf3gIOGjbpQ"}}},
      },
    }));
    assert.deepEqual(event, {
      eventId: "a4319bc8-ed16-460b-8de6-ba9734b55631",
      type: "betaFeedbackCrashSubmissionCreated",
      instanceId: "AK7UjG-qL5QxXf3gIOGjbpQ",
    });
    assert.equal(testFlightKind(event.type), "testflightCrash");
    assert.equal(testFlightKind("betaFeedbackScreenshotSubmissionCreated"), "testflightFeedback");
    assert.equal(testFlightKind("buildUploadStateUpdated"), null);
    assert.throws(() => parseWebhookEvent(JSON.stringify({data: {}})));
  });

  it("files a TestFlight crash as high, keeping the log off the ping", () => {
    const observation = testFlightObservation({
      kind: "testflightCrash",
      submissionId: "AK7UjG",
      submission: {comment: "翻頁時閃退\n第二行", deviceModel: "iPhone16,1", osVersion: "26.6.1", locale: "zh-Hant"},
      appVersion: "2.0.7 (127)",
      crashLog: "Exception Type: EXC_BAD_ACCESS\n" + "x".repeat(maxDetailLength),
      screenshotPaths: [],
    });
    assert.equal(observation.id, "testflight_AK7UjG");
    assert.equal(observation.severity, "high");
    assert.equal(observation.title, "翻頁時閃退");
    assert.equal(observation.summary, "翻頁時閃退\n第二行\niPhone16,1 · 26.6.1 · zh-Hant");
    assert.equal(observation.detail?.length, maxDetailLength);
    assert.equal(observation.attachmentPaths, undefined);
    assert.doesNotMatch(telegramMessage(observation), /EXC_BAD_ACCESS/);
  });

  it("files screenshot feedback without a comment as normal, with its copies", () => {
    const observation = testFlightObservation({
      kind: "testflightFeedback", submissionId: "AD8J", submission: {}, appVersion: "2.0.7 (127)",
      screenshotPaths: ["triage/testflight/AD8J/0.jpg"],
    });
    assert.equal(observation.severity, "normal");
    assert.equal(observation.title, "TestFlight 回饋（沒有留言）");
    assert.deepEqual(observation.attachmentPaths, ["triage/testflight/AD8J/0.jpg"]);
  });

  it("keeps one Organizer item per signature across builds", () => {
    const a = {id: "build-1-sig", diagnosticType: "HANGS" as const, signature: "Yuedu: -[A b] + 1", weight: 0.6};
    const b = {...a, id: "build-2-sig", weight: 0.4};
    assert.equal(diagnosticItemId(a), diagnosticItemId(b));
    assert.notEqual(diagnosticItemId(a), diagnosticItemId({...a, diagnosticType: "DISK_WRITES"}));
    const observation = diagnosticObservation({signature: a, appVersion: "2.0.7 (127)", insights: ["Use an index."], callStack: ""});
    assert.equal(observation.summary, "佔這個 build 卡頓回報的 60%\nUse an index.");
    assert.equal(observation.severity, "normal");
    assert.equal(observation.detail, undefined);
  });

  it("records signatures above the noise floor, heaviest first", () => {
    const base = {diagnosticType: "HANGS" as const, signature: "s"};
    const kept = signaturesWorthRecording([
      {...base, id: "a", weight: 0.04}, {...base, id: "b", weight: 0.1}, {...base, id: "c", weight: 0.7},
    ]);
    assert.deepEqual(kept.map((signature) => signature.id), ["c", "b"]);
  });

  it("follows the heaviest path through the call stack", () => {
    const text = summarizeDiagnosticLogs({
      productData: [{
        diagnosticLogs: [{
          diagnosticMetaData: {event: "hang", appVersion: "2.0.7"},
          callStackTree: [{callStacks: [{callStackRootFrames: [
            {rawFrame: "root light", sampleCount: 1},
            {rawFrame: "root heavy", sampleCount: 9, subFrames: [
              {rawFrame: "child light", sampleCount: 2},
              {rawFrame: "ReaderView.layout (ReaderView.swift:42)", sampleCount: 7, isBlameFrame: true},
            ]},
          ]}]}],
        }],
      }],
    });
    assert.equal(text, "event: hang\nappVersion: 2.0.7\n\n  root heavy\n▶ ReaderView.layout (ReaderView.swift:42)");
    assert.equal(summarizeDiagnosticLogs({productData: []}), "");
  });

  it("reads every build even when one fails, then reports the failures", async () => {
    const read: string[] = [];
    const failed: string[] = [];
    await assert.rejects(
      readEachBuild(
        ["2.0.7 (127)", "2.0.8 (1)", "2.0.8 (2)"],
        (build) => build,
        async (build) => {
          if (build === "2.0.7 (127)") throw new Error("404 NOT_FOUND");
          read.push(build);
        },
        (build, error) => failed.push(`${build}: ${String(error)}`),
      ),
      /1 of 3 builds failed: 2\.0\.7 \(127\)/
    );
    assert.deepEqual(read, ["2.0.8 (1)", "2.0.8 (2)"]);
    assert.deepEqual(failed, ["2.0.7 (127): Error: 404 NOT_FOUND"]);
  });

  it("finishes quietly when every build reads", async () => {
    const read: string[] = [];
    await readEachBuild(["a", "b"], (build) => build, async (build) => { read.push(build); }, () => assert.fail());
    assert.deepEqual(read, ["a", "b"]);
  });
});
