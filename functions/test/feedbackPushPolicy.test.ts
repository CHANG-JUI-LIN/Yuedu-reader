import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {apnsPayload, feedbackPushFor, pushDevice, tokenIsDead} from "../src/feedbackPushPolicy.js";

const earlier = new Date("2026-10-19T10:00:00Z");
const later = new Date("2026-10-19T10:05:00Z");

describe("feedback push policy", () => {
  it("announces a developer or assistant reply with its preview", () => {
    const push = feedbackPushFor(
      {status: "queued", lastReplyAt: earlier},
      {status: "queued", lastReplyAt: later, lastMessagePreview: "已修好，下一版上線"}
    );
    assert.deepEqual(push, {kind: "reply", preview: "已修好，下一版上線"});
  });

  it("sends one notification for a reply that also changes the status", () => {
    const push = feedbackPushFor(
      {status: "processing", lastReplyAt: earlier},
      {status: "done", lastReplyAt: later, lastMessagePreview: "已修好"}
    );
    assert.deepEqual(push, {kind: "done", preview: "已修好"});
    // The AI 助手's first reply: no lastReplyAt before.
    assert.deepEqual(
      feedbackPushFor({status: "received"}, {status: "needsInfo", lastReplyAt: later, lastMessagePreview: "請補截圖"}),
      {kind: "needsInfo", preview: "請補截圖"}
    );
  });

  it("announces 待補充 and 已完成 without a reply, and stays quiet for internal progress", () => {
    assert.deepEqual(feedbackPushFor({status: "processing"}, {status: "done"}), {kind: "done", preview: null});
    assert.deepEqual(feedbackPushFor({status: "queued"}, {status: "needsInfo"}), {kind: "needsInfo", preview: null});
    assert.equal(feedbackPushFor({status: "queued"}, {status: "processing"}), null);
    assert.equal(feedbackPushFor({status: "received"}, {status: "queued"}), null);
  });

  it("ignores the user's own writes", () => {
    // Their reply moves lastMessageAt, never lastReplyAt.
    assert.equal(feedbackPushFor(
      {status: "needsInfo", lastReplyAt: earlier, lastMessageAt: earlier},
      {status: "queued", lastReplyAt: earlier, lastMessageAt: later, lastMessageAuthor: "user"}
    ), null);
    // Their 標記為已完成.
    assert.equal(feedbackPushFor({status: "processing"}, {status: "done", userResolvedAt: later}), null);
    // Reading the thread.
    assert.equal(feedbackPushFor({status: "done", userLastReadAt: earlier}, {status: "done", userLastReadAt: later}), null);
  });

  it("still announces a developer's 已完成 after the user resolved earlier", () => {
    assert.deepEqual(
      feedbackPushFor({status: "queued", userResolvedAt: earlier}, {status: "done", userResolvedAt: earlier}),
      {kind: "done", preview: null}
    );
  });

  it("compares Firestore Timestamps by instant", () => {
    const stamp = (date: Date) => ({toMillis: () => date.getTime()});
    assert.equal(feedbackPushFor({status: "queued", lastReplyAt: stamp(earlier)}, {status: "queued", lastReplyAt: stamp(earlier)}), null);
  });

  it("builds an alert localized on the device, without a badge", () => {
    const withReply = apnsPayload({kind: "reply", preview: "已修好"}, "t1", "翻頁卡住");
    assert.deepEqual(withReply, {
      aps: {alert: {"subtitle-loc-key": "回饋推播：新回覆", "title": "翻頁卡住", "body": "已修好"}, "sound": "default", "thread-id": "t1"},
      feedbackThread: "t1",
    });
    const statusOnly = apnsPayload({kind: "done", preview: null}, "t1", "");
    assert.deepEqual((statusOnly.aps as {alert: unknown}).alert, {
      "subtitle-loc-key": "回饋推播：已完成",
      "loc-key": "回饋推播：已完成內文",
    });
  });

  it("accepts only well-formed device entries and retires dead tokens", () => {
    assert.deepEqual(pushDevice({token: "ab".repeat(32), environment: "production"}), {token: "ab".repeat(32), environment: "production"});
    assert.equal(pushDevice({token: "xyz", environment: "production"}), null);
    assert.equal(pushDevice({token: "ab".repeat(32), environment: "staging"}), null);
    assert.equal(tokenIsDead(410, "Unregistered"), true);
    assert.equal(tokenIsDead(400, "BadDeviceToken"), true);
    assert.equal(tokenIsDead(400, "BadCollapseId"), false);
    assert.equal(tokenIsDead(429, "TooManyRequests"), false);
  });
});
