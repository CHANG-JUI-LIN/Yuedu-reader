/**
 * App Review and TestFlight install the same uploaded binary, and both run it in the
 * Sandbox, so the app cannot tell a reviewer from a tester on its own. App Store Connect
 * can: the build attached to an App Store version that is waiting for or in review is the
 * one a reviewer opens. That build keeps its purchases; every other TestFlight build has
 * none (TestFlight purchases are free, so they would hand out Pro).
 */

/** App Store version states in which App Review may open the attached build. */
export const reviewStates: readonly string[] = ["WAITING_FOR_REVIEW", "IN_REVIEW"];

/** `GET /v1/apps/{id}/appStoreVersions?include=build`, the fields this reads. */
export interface AppStoreVersionsPayload {
  data?: Array<{
    attributes?: {versionString?: string; appVersionState?: string};
    relationships?: {build?: {data?: {type?: string; id?: string} | null}};
  }>;
  included?: Array<{type?: string; id?: string; attributes?: {version?: string}}>;
}

export interface BuildIdentity {
  /** `CFBundleShortVersionString`, e.g. "3.0.0". */
  version: string;
  /** `CFBundleVersion`, e.g. "6". */
  build: string;
}

// ASCII digits only: a version or build number never holds anything else.
const identifierPattern = /^[0-9]+(\.[0-9]+){0,3}$/;

export function reviewBuildKey(identity: BuildIdentity): string {
  return `${identity.version}|${identity.build}`;
}

/** The callable's input, or null when it is not a version and build number pair. */
export function parseBuildIdentity(data: unknown): BuildIdentity | null {
  if (typeof data !== "object" || data === null) return null;
  const {version, build} = data as {version?: unknown; build?: unknown};
  if (typeof version !== "string" || typeof build !== "string") return null;
  if (!identifierPattern.test(version) || !identifierPattern.test(build)) return null;
  return {version, build};
}

/**
 * Keys of every build attached to a version waiting for or in review. The state is
 * checked here as well as in the request filter, so a filter App Store Connect ignored
 * can only ever narrow the answer, never let a TestFlight build buy.
 */
export function buildsUnderReview(payload: AppStoreVersionsPayload): Set<string> {
  const buildNumbers = new Map<string, string>();
  for (const resource of payload.included ?? []) {
    if (resource.type === "builds" && resource.id !== undefined && resource.attributes?.version !== undefined) {
      buildNumbers.set(resource.id, resource.attributes.version);
    }
  }
  const keys = new Set<string>();
  for (const version of payload.data ?? []) {
    const state = version.attributes?.appVersionState;
    const versionString = version.attributes?.versionString;
    const buildId = version.relationships?.build?.data?.id;
    if (state === undefined || !reviewStates.includes(state)) continue;
    if (versionString === undefined || buildId === undefined) continue;
    const build = buildNumbers.get(buildId);
    if (build === undefined) continue;
    keys.add(reviewBuildKey({version: versionString, build}));
  }
  return keys;
}
