import {getStorage} from "firebase-admin/storage";
import {logger} from "firebase-functions";
import {defineSecret} from "firebase-functions/params";
import {onRequest} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";

import {AppStoreConnectClient} from "./appStoreConnect.js";
import {
  appAppleId,
  appStoreIssuerIdSecret,
  appStoreKeyIdSecret,
  appStoreKeySecrets,
  appStorePrivateKeySecret,
} from "./appStoreConnectSecrets.js";
import {
  DiagnosticLogsResponse,
  DiagnosticSignature,
  TestFlightKind,
  TestFlightSubmission,
  diagnosticInsights,
  diagnosticObservation,
  parseWebhookEvent,
  readEachBuild,
  signaturesWorthRecording,
  summarizeDiagnosticLogs,
  testFlightKind,
  testFlightObservation,
  verifyAppleSignature,
} from "./appleTriagePolicy.js";
import {recordObservation, triageSecrets} from "./triage.js";

// The Apple side of the triage inbox (Technotes/TriageWorkflow.md, phase B): TestFlight
// feedback arrives through an App Store Connect webhook, and Xcode Organizer's diagnostic
// signatures are read once a day. Both go through `recordObservation` like everything else.

const region = "asia-east1";

/// The secret typed into App Store Connect › Users and Access › Integrations › Webhooks.
const webhookSecret = defineSecret("APP_STORE_CONNECT_WEBHOOK_SECRET");

function connectClient(): AppStoreConnectClient {
  return new AppStoreConnectClient({
    credentials: {
      issuerId: appStoreIssuerIdSecret.value(),
      keyId: appStoreKeyIdSecret.value(),
      privateKeyBase64: appStorePrivateKeySecret.value(),
    },
    appId: String(appAppleId),
  });
}

interface Resource<A> {
  id: string;
  type: string;
  attributes?: A;
  relationships?: Record<string, {data?: {id: string; type: string} | null}>;
}

interface Document<A> {
  data: Resource<A>;
  included?: Array<Resource<Record<string, unknown>>>;
}

/// "2.0.7 (127)", the form the app and Crashlytics use.
async function buildVersion(client: AppStoreConnectClient, buildId: string): Promise<string> {
  const build = await client.getJSON<Document<{version?: string}>>(
    `/builds/${buildId}?include=preReleaseVersion&fields[builds]=version,preReleaseVersion&fields[preReleaseVersions]=version`
  );
  const marketing = build.included?.find((item) => item.type === "preReleaseVersions")?.attributes?.version;
  return `${typeof marketing === "string" ? marketing : "?"} (${build.data.attributes?.version ?? "?"})`;
}

interface ScreenshotImage {
  url?: string;
}

/// The submission's screenshots, copied into Storage: Apple's URLs expire, and the
/// daily run may read them days later.
async function copyScreenshots(
  client: AppStoreConnectClient, submissionId: string, images: ScreenshotImage[]
): Promise<string[]> {
  const bucket = getStorage().bucket();
  const paths: string[] = [];
  for (const [index, image] of images.entries()) {
    if (image.url === undefined) continue;
    const response = await fetch(image.url, {signal: AbortSignal.timeout(30_000)});
    if (!response.ok) throw new Error(`screenshot ${index} of ${submissionId}: HTTP ${response.status}`);
    const contentType = response.headers.get("content-type") ?? "image/jpeg";
    const extension = contentType.includes("png") ? "png" : "jpg";
    const path = `triage/testflight/${submissionId}/${index}.${extension}`;
    await bucket.file(path).save(Buffer.from(await response.arrayBuffer()), {contentType});
    paths.push(path);
  }
  return paths;
}

async function recordTestFlightSubmission(kind: TestFlightKind, submissionId: string, eventId: string): Promise<void> {
  const client = connectClient();
  const collection = kind === "testflightCrash" ? "betaFeedbackCrashSubmissions" : "betaFeedbackScreenshotSubmissions";
  const submission = await client.getJSON<Document<TestFlightSubmission & {screenshots?: ScreenshotImage[]}>>(
    `/${collection}/${submissionId}?include=build`
  );
  const buildId = submission.data.relationships?.build?.data?.id;
  const appVersion = buildId !== undefined ? await buildVersion(client, buildId) : "";
  const crashLog = kind === "testflightCrash"
    ? (await client.getJSON<Document<{logText?: string}>>(`/betaFeedbackCrashSubmissions/${submissionId}/crashLog`))
      .data.attributes?.logText
    : undefined;
  const screenshotPaths = await copyScreenshots(client, submissionId, submission.data.attributes?.screenshots ?? []);
  await recordObservation(testFlightObservation({
    kind,
    submissionId,
    submission: submission.data.attributes ?? {},
    appVersion,
    ...(crashLog !== undefined ? {crashLog} : {}),
    screenshotPaths,
  }), eventId);
}

/// The App Store Connect webhook. Register its URL with the TestFlight feedback events
/// (BETA_FEEDBACK_CRASH_SUBMISSION_CREATED, BETA_FEEDBACK_SCREENSHOT_SUBMISSION_CREATED).
///
/// A delivery without a valid signature is refused with 401. Other event types (a ping
/// from "Test", or events added to the webhook later) are acknowledged and logged. When
/// reading the submission fails the answer is 500, so the delivery shows as failed in
/// App Store Connect and can be redelivered from there; the event id keeps a redelivery
/// from counting twice.
export const appStoreConnectWebhook = onRequest(
  {region, secrets: [webhookSecret, ...appStoreKeySecrets, ...triageSecrets], timeoutSeconds: 120},
  async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).send("POST only");
      return;
    }
    if (!verifyAppleSignature(request.rawBody, request.get("x-apple-signature"), webhookSecret.value())) {
      logger.warn("App Store Connect webhook: bad signature");
      response.status(401).send("bad signature");
      return;
    }
    let event;
    try {
      event = parseWebhookEvent(request.rawBody.toString("utf8"));
    } catch (error) {
      // The body is signed by Apple, so its start is safe to log: it shows the shape of an
      // event this parser does not know (the 「測試」 ping's shape is not documented).
      logger.error("App Store Connect webhook: unreadable body", {
        error: String(error), body: request.rawBody.toString("utf8").slice(0, 300),
      });
      response.status(400).send("unreadable body");
      return;
    }
    const kind = testFlightKind(event.type);
    if (kind === null || event.instanceId === null) {
      logger.info("App Store Connect webhook: event not filed", {type: event.type, eventId: event.eventId});
      response.status(200).send("ignored");
      return;
    }
    try {
      await recordTestFlightSubmission(kind, event.instanceId, event.eventId);
      response.status(200).send("filed");
    } catch (error) {
      logger.error("App Store Connect webhook: filing failed", {type: event.type, instance: event.instanceId, error: String(error)});
      response.status(500).send("filing failed");
    }
  }
);

/// Organizer's data lags a release by days, so the last few builds are read, not only
/// the newest.
const diagnosticBuilds = 3;

interface BuildList {
  data: Array<Resource<{version?: string}>>;
  included?: Array<Resource<Record<string, unknown>>>;
}

interface SignatureList {
  data: Array<Resource<Omit<DiagnosticSignature, "id">>>;
}

/// Every morning before the 08:30 triage run: each recent build's diagnostic signatures
/// above the noise floor, with the heaviest call stack of one log each, into the inbox.
/// The event id is the build and the day, so a retried run counts each signature once.
export const dailyOrganizerDiagnostics = onSchedule(
  {
    schedule: "0 5 * * *",
    timeZone: "Asia/Taipei",
    region,
    secrets: [...appStoreKeySecrets, ...triageSecrets],
    timeoutSeconds: 540,
  },
  async () => {
    const client = connectClient();
    const day = new Date().toISOString().slice(0, 10);
    const builds = await client.getJSON<BuildList>(
      `/builds?filter[app]=${appAppleId}&sort=-uploadedDate&limit=${diagnosticBuilds}` +
      "&include=preReleaseVersion&fields[builds]=version,preReleaseVersion&fields[preReleaseVersions]=version"
    );
    const versionOf = (build: Resource<{version?: string}>): string => {
      const preReleaseId = build.relationships?.preReleaseVersion?.data?.id;
      const marketing = builds.included?.find((item) => item.id === preReleaseId)?.attributes?.version;
      return `${typeof marketing === "string" ? marketing : "?"} (${build.attributes?.version ?? "?"})`;
    };
    // Oldest first, so the newest build's share is the one an item's summary ends on.
    await readEachBuild([...builds.data].reverse(), (build) => `${versionOf(build)} ${build.id}`, async (build) => {
      const appVersion = versionOf(build);
      const signatures = await client.getJSON<SignatureList>(
        `/builds/${build.id}/diagnosticSignatures?fields[diagnosticSignatures]=diagnosticType,signature,weight&limit=200`
      );
      const worth = signaturesWorthRecording(signatures.data.flatMap((item) => {
        const attributes = item.attributes;
        return attributes === undefined ? [] : [{id: item.id, ...attributes}];
      }));
      logger.info("Organizer diagnostics", {build: appVersion, signatures: signatures.data.length, recorded: worth.length});
      for (const signature of worth) {
        // Answers `application/vnd.apple.diagnostic-logs+json`; fetch's default `Accept: */*` takes it.
        const logs = await client.getJSON<DiagnosticLogsResponse>(`/diagnosticSignatures/${signature.id}/logs?limit=1`);
        await recordObservation(diagnosticObservation({
          signature,
          appVersion,
          insights: diagnosticInsights(logs),
          callStack: summarizeDiagnosticLogs(logs),
        }), `organizer:${build.id}:${day}`);
      }
    }, (build, error) => logger.error("Organizer diagnostics: build failed", {build, error: String(error)}));
  }
);
