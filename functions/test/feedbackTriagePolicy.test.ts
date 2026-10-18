import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
  assistantMayReply,
  assistantRepliesPerInboxPerDay,
  messagePreview,
  parseTriage,
  triageSystemPrompt,
  triageUserMessage,
} from "../src/feedbackTriagePolicy.js";

describe("feedback triage policy", () => {
  it("accepts a well-formed answer and bounds the title", () => {
    const result = parseTriage(JSON.stringify({
      title: "海".repeat(60),
      reply: "  已收到你的回報。 ",
      status: "needsInfo",
      severity: "high",
    }));
    assert.equal(result.reply, "已收到你的回報。");
    assert.equal(result.status, "needsInfo");
    assert.equal(result.severity, "high");
    assert.equal(Array.from(result.title).length, 40);
  });

  it("rejects an empty reply and statuses the client may not see from triage", () => {
    assert.throws(() => parseTriage(JSON.stringify({title: "x", reply: " ", status: "queued", severity: "low"})));
    assert.throws(() => parseTriage(JSON.stringify({title: "x", reply: "ok", status: "done", severity: "low"})));
    assert.throws(() => parseTriage("not json"));
  });

  it("keeps the reply when the severity is missing or unknown", () => {
    for (const severity of [undefined, "medium"]) {
      const result = parseTriage(JSON.stringify({title: "x", reply: "ok", status: "queued", severity}));
      assert.equal(result.reply, "ok");
      assert.equal(result.severity, null);
    }
  });

  it("asks DeepSeek's JSON mode for JSON by name", () => {
    // JSON mode refuses a prompt that never mentions JSON.
    assert.match(triageSystemPrompt, /JSON/);
  });

  it("keeps a Simplified Chinese user in Simplified", () => {
    // 8 of 12 zh-Hans users got Traditional replies (2026-10-17) when the rule only
    // forbade switching away from Traditional.
    assert.match(triageSystemPrompt, /Simplified Chinese gets Simplified Chinese/);
    assert.match(triageSystemPrompt, /来源配置/);
  });

  it("describes attachments it cannot show", () => {
    const message = triageUserMessage({
      kind: "bug", text: "閃退", locale: "zh-Hant_TW", appVersion: "1.0.1 (200)",
      osVersion: "iOS 27.2", device: "iPhone18,2", imageCount: 2, videoCount: 1,
    });
    assert.match(message, /2 screenshot\(s\), shown above/);
    assert.match(message, /1 screen recording\(s\), not shown/);
    assert.match(message, /<report>\n閃退\n<\/report>/);
  });

  it("answers up to the daily limit, counting the new thread", () => {
    assert.equal(assistantMayReply(1), true);
    assert.equal(assistantMayReply(assistantRepliesPerInboxPerDay), true);
    assert.equal(assistantMayReply(assistantRepliesPerInboxPerDay + 1), false);
  });

  it("previews the first lines on one line", () => {
    assert.equal(messagePreview("  第一行\n\n第二行  "), "第一行 第二行");
    assert.equal(Array.from(messagePreview("字".repeat(500))).length, 120);
  });
});
