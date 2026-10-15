import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  crashlyticsObservation,
  feedbackItemId,
  feedbackObservation,
  mergedStatus,
  shouldNotify,
  telegramMessage,
  telegramTextLimit,
} from "../src/triagePolicy.js";

const issue = {id: "abc123", title: "EXC_BAD_ACCESS", subtitle: "ReaderView.swift line 42", appVersion: "1.0.1 (210)"};
const projectId = "yuedu-readerr";
const appId = "1:540650701012:ios:e1db6b9aa1aea37246bb41";

describe("triage policy", () => {
  it("files every alert about one Crashlytics issue under that issue", () => {
    const fatal = crashlyticsObservation({kind: "newFatal", issue, projectId, appId});
    const velocity = crashlyticsObservation({kind: "velocity", issue, projectId, appId, count: 40});
    assert.equal(fatal.id, "crashlytics_abc123");
    assert.equal(velocity.id, fatal.id);
    assert.equal(fatal.severity, "high");
    assert.equal(velocity.severity, "critical");
    assert.equal(velocity.count, 40);
    assert.equal(
      fatal.sourceRef,
      `https://console.firebase.google.com/v1/appid/project/${projectId}/crashlytics/app/${appId}/issues/abc123`
    );
  });

  it("keeps feedback and Crashlytics ids apart", () => {
    assert.notEqual(feedbackItemId("abc123"), crashlyticsObservation({kind: "newFatal", issue, projectId, appId}).id);
  });

  it("never puts the inbox key into a feedback ping", () => {
    const observation = feedbackObservation({
      threadId: "0f8e6c1a-1111-2222-3333-444455556666", number: 42, title: "閃退", text: "打開書就閃退",
      severity: null, appVersion: "1.0.1 (210)", installId: "install-1",
      threadPath: "feedbackInboxes/SECRETINBOXKEY/threads/0f8e6c1a-1111-2222-3333-444455556666",
    });
    assert.equal(observation.threadPath, "feedbackInboxes/SECRETINBOXKEY/threads/0f8e6c1a-1111-2222-3333-444455556666");
    assert.equal(observation.severity, "normal");
    assert.equal(observation.id, "feedback_0f8e6c1a-1111-2222-3333-444455556666");
    const text = telegramMessage({...observation, severity: "high"});
    assert.doesNotMatch(text, /feedbackInboxes|SECRETINBOXKEY/);
    assert.match(text, /^🟠 嚴重｜使用者回饋\n#42 閃退\n/);
    assert.match(text, /tools\/feedback\.ts show 42/);
  });

  it("pings when a problem first reaches high, not again at the same level", () => {
    assert.equal(shouldNotify(null, {kind: "newFatal", severity: "high"}), true);
    assert.equal(shouldNotify({severity: "high", status: "new"}, {kind: "newFatal", severity: "high"}), false);
    assert.equal(shouldNotify({severity: "normal", status: "new"}, {kind: "feedback", severity: "high"}), true);
    assert.equal(shouldNotify({severity: "high", status: "new"}, {kind: "feedback", severity: "critical"}), true);
  });

  it("does not ping for normal or low", () => {
    assert.equal(shouldNotify(null, {kind: "newNonfatal", severity: "normal"}), false);
    assert.equal(shouldNotify(null, {kind: "feedback", severity: "low"}), false);
    assert.equal(shouldNotify(null, {kind: "stabilityDigest", severity: "normal"}), false);
  });

  it("always pings a regression or a velocity spike", () => {
    const existing = {severity: "critical" as const, status: "fixing"};
    assert.equal(shouldNotify(existing, {kind: "regression", severity: "high"}), true);
    assert.equal(shouldNotify(existing, {kind: "velocity", severity: "critical"}), true);
  });

  it("reopens a shipped item on regression and keeps the status otherwise", () => {
    assert.equal(mergedStatus(null, "newFatal"), "new");
    assert.equal(mergedStatus({severity: "high", status: "shipped"}, "regression"), "new");
    assert.equal(mergedStatus({severity: "high", status: "wontfix"}, "regression"), "new");
    assert.equal(mergedStatus({severity: "high", status: "fixing"}, "regression"), "fixing");
    assert.equal(mergedStatus({severity: "high", status: "shipped"}, "velocity"), "shipped");
  });

  it("writes a plain-text ping within Telegram's limit", () => {
    const observation = crashlyticsObservation({kind: "velocity", issue, projectId, appId, count: 40});
    const text = telegramMessage(observation);
    assert.match(text, /^🔴 緊急｜Crashlytics 崩潰暴增\nEXC_BAD_ACCESS\n\nReaderView\.swift line 42\n\n版本 1\.0\.1 \(210\)\n次數 40\n/);
    assert.ok(text.endsWith(observation.sourceRef));

    const long = telegramMessage({...observation, summary: "字".repeat(10_000)});
    assert.equal(long.length, telegramTextLimit);
    assert.ok(long.endsWith("…"));
  });
});
