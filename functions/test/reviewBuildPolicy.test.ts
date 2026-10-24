import assert from "node:assert/strict";
import {describe, it} from "node:test";
import {buildsUnderReview, parseBuildIdentity, reviewBuildKey} from "../src/reviewBuildPolicy.js";

function version(state: string, versionString: string, buildId: string | null) {
  return {
    attributes: {versionString, appVersionState: state},
    relationships: {build: {data: buildId === null ? null : {type: "builds", id: buildId}}},
  };
}

function build(id: string, number: string) {
  return {type: "builds", id, attributes: {version: number}};
}

describe("builds under App Review", () => {
  it("names the build attached to a version waiting for or in review", () => {
    const keys = buildsUnderReview({
      data: [version("WAITING_FOR_REVIEW", "3.0.0", "b6"), version("IN_REVIEW", "2.0.8", "b2")],
      included: [build("b6", "6"), build("b2", "2")],
    });
    assert.deepEqual([...keys].sort(), ["2.0.8|2", "3.0.0|6"]);
  });

  it("ignores versions in any other state, even if the request filter was not applied", () => {
    const keys = buildsUnderReview({
      data: [
        version("READY_FOR_DISTRIBUTION", "2.0.7", "b1"),
        version("PREPARE_FOR_SUBMISSION", "3.0.0", "b5"),
        version("PENDING_DEVELOPER_RELEASE", "3.0.0", "b6"),
      ],
      included: [build("b1", "1"), build("b5", "5"), build("b6", "6")],
    });
    assert.equal(keys.size, 0);
  });

  it("ignores a version with no build attached or a build it was not sent", () => {
    const keys = buildsUnderReview({
      data: [version("IN_REVIEW", "3.0.0", null), version("IN_REVIEW", "3.0.1", "missing")],
      included: [],
    });
    assert.equal(keys.size, 0);
  });

  it("matches only the exact version and build pair", () => {
    const keys = buildsUnderReview({
      data: [version("IN_REVIEW", "3.0.0", "b6")],
      included: [build("b6", "6")],
    });
    assert.equal(keys.has(reviewBuildKey({version: "3.0.0", build: "6"})), true);
    assert.equal(keys.has(reviewBuildKey({version: "3.0.0", build: "5"})), false);
    assert.equal(keys.has(reviewBuildKey({version: "3.0.1", build: "6"})), false);
  });
});

describe("build identity input", () => {
  it("accepts a version and build number", () => {
    assert.deepEqual(parseBuildIdentity({version: "3.0.0", build: "6"}), {version: "3.0.0", build: "6"});
    assert.deepEqual(parseBuildIdentity({version: "3.0", build: "6.1"}), {version: "3.0", build: "6.1"});
  });

  it("rejects anything else", () => {
    for (const data of [
      null, "3.0.0", {}, {version: "3.0.0"}, {version: 3, build: "6"},
      {version: "3.0.0", build: ""}, {version: "3.0.0|6", build: "6"}, {version: "三.0", build: "6"},
    ]) {
      assert.equal(parseBuildIdentity(data), null);
    }
  });
});
