import assert from "node:assert/strict";
import {describe, it} from "node:test";

import {threadStatusAfterTriage, threadStatusForTriage} from "../src/feedbackStatusSyncPolicy.js";

describe("feedback status sync policy", () => {
  it("shows a claimed or committed fix as 處理中 and a released one as 已完成", () => {
    assert.equal(threadStatusForTriage("fixing"), "processing");
    assert.equal(threadStatusForTriage("fixed"), "processing");
    assert.equal(threadStatusForTriage("shipped"), "done");
  });

  it("leaves the thread alone for new, triaged and wontfix items", () => {
    assert.equal(threadStatusForTriage("new"), null);
    assert.equal(threadStatusForTriage("triaged"), null);
    assert.equal(threadStatusForTriage("wontfix"), null);
    assert.equal(threadStatusForTriage(undefined), null);
  });

  it("moves a waiting thread forward, including one waiting on the user", () => {
    assert.equal(threadStatusAfterTriage("queued", "fixing"), "processing");
    assert.equal(threadStatusAfterTriage("received", "fixed"), "processing");
    assert.equal(threadStatusAfterTriage("needsInfo", "fixed"), "processing");
    assert.equal(threadStatusAfterTriage("queued", "shipped"), "done");
    assert.equal(threadStatusAfterTriage("processing", "shipped"), "done");
  });

  it("never moves a thread backwards or out of 已完成", () => {
    // The user's own 標記為已完成, or the developer's reply --status done.
    assert.equal(threadStatusAfterTriage("done", "fixing"), null);
    assert.equal(threadStatusAfterTriage("done", "shipped"), null);
    // fixing → fixed is the same 處理中; a redelivered event writes nothing.
    assert.equal(threadStatusAfterTriage("processing", "fixed"), null);
    // An item put back to triaged keeps 處理中.
    assert.equal(threadStatusAfterTriage("processing", "triaged"), null);
  });

  it("reads an unknown thread status as not yet picked up, as the app does", () => {
    assert.equal(threadStatusAfterTriage("someFutureStatus", "fixing"), "processing");
    assert.equal(threadStatusAfterTriage(undefined, "shipped"), "done");
  });
});
