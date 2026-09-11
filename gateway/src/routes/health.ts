import {Router} from "express";

import type {GatewayContext} from "../context.js";
import {withTimeout} from "../withTimeout.js";

export function healthRouter(context: GatewayContext): Router {
  const router = Router();

  /** Liveness: the process is up. No upstream dependency. */
  router.get("/healthz", (_request, response) => {
    response.json({status: "ok"});
  });

  /**
   * Readiness: verifies the process can reach Firestore and Cloud Storage.
   * Metadata calls only — no document reads, no user data.
   *
   * When the Admin credential has not resolved a token yet, the upstreams are
   * not called at all: the Firestore client tries to load Application Default
   * Credentials lazily and leaks a rejection (and throws from a timer) when
   * they are missing. Reporting `credentials-unavailable` is both accurate and
   * the only path that cannot take the process down.
   */
  router.get("/readyz", async (_request, response) => {
    if (!context.credentialsReady) {
      response.status(503).json({
        status: "degraded",
        checks: {credentials: "unavailable", firestore: "skipped", storage: "skipped"},
      });
      return;
    }
    const checks = {credentials: "ok", firestore: "unknown", storage: "unknown"};
    try {
      await withTimeout(context.firestore.listCollections(), context.config.upstreamTimeoutMs);
      checks.firestore = "ok";
    } catch {
      checks.firestore = "unreachable";
    }
    try {
      const [exists] = await withTimeout(
        context.storage.bucket().exists(),
        context.config.upstreamTimeoutMs
      );
      checks.storage = exists ? "ok" : "missing";
    } catch {
      checks.storage = "unreachable";
    }
    const ready = checks.firestore === "ok" && checks.storage === "ok";
    response.status(ready ? 200 : 503).json({status: ready ? "ready" : "degraded", checks});
  });

  return router;
}
