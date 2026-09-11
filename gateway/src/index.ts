import {buildContext, startServer, verifyStartupCredentials} from "./server.js";
import {logError, logEvent} from "./logger.js";

async function main(): Promise<void> {
  const context = buildContext();
  const server = startServer(context);

  let shuttingDown = false;
  const shutdown = (exitCode: number, reason: string): void => {
    if (shuttingDown) return;
    shuttingDown = true;
    logEvent("shutdown requested", {reason, exitCode});
    server.close((error) => {
      if (error !== undefined) {
        logError("shutdown failed", error);
        process.exit(1);
      }
      process.exit(exitCode);
    });
    // Do not let an in-flight connection hold the process open forever.
    setTimeout(() => process.exit(exitCode), 10_000).unref();
  };

  process.on("SIGTERM", () => shutdown(0, "SIGTERM"));
  process.on("SIGINT", () => shutdown(0, "SIGINT"));

  // Expected request failures (bad credentials, upstream timeouts, malformed
  // tokens) are handled where their promises are created. An unhandled
  // rejection therefore means a code defect or an SDK leak — unrecoverable
  // state, not a request to swallow. Log it and restart the process rather
  // than serving in an unknown state. `uncaughtException` is deliberately not
  // handled: Node's default crash plus the supervisor restart is correct.
  process.on("unhandledRejection", (reason) => {
    logError("unhandled promise rejection; treating as unrecoverable", reason);
    shutdown(1, "unhandledRejection");
  });

  const ready = await verifyStartupCredentials(context);
  if (!ready) {
    logEvent("gateway running degraded until credentials are restored and the process restarts");
  }
}

main().catch((error) => {
  logError("gateway failed to start", error);
  process.exit(1);
});
