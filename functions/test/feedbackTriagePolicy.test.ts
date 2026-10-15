import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {
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
    }));
    assert.equal(result.reply, "已收到你的回報。");
    assert.equal(result.status, "needsInfo");
    assert.equal(Array.from(result.title).length, 40);
  });

  it("rejects an empty reply and statuses the client may not see from triage", () => {
    assert.throws(() => parseTriage(JSON.stringify({title: "x", reply: " ", status: "queued"})));
    assert.throws(() => parseTriage(JSON.stringify({title: "x", reply: "ok", status: "done"})));
    assert.throws(() => parseTriage("not json"));
  });

  it("asks DeepSeek's JSON mode for JSON by name", () => {
    // JSON mode refuses a prompt that never mentions JSON.
    assert.match(triageSystemPrompt, /JSON/);
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

  it("previews the first lines on one line", () => {
    assert.equal(messagePreview("  第一行\n\n第二行  "), "第一行 第二行");
    assert.equal(Array.from(messagePreview("字".repeat(500))).length, 120);
  });
});
