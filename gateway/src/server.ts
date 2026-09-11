import express, {type NextFunction, type Request, type Response} from "express";

import {requireAuth} from "./auth.js";
import {createCallableCaller} from "./callableProxy.js";
import {loadConfig} from "./config.js";
import type {GatewayContext} from "./context.js";
import {ApiError, errorBody, mapBodyParserError} from "./errors.js";
import {initFirebase} from "./firebase.js";
import {createRequestId, logError, logEvent, logRequest} from "./logger.js";
import {RateLimiter, rateLimitMiddleware} from "./rateLimit.js";
import {withTimeout} from "./withTimeout.js";
import {accountRouter} from "./routes/account.js";
import {authRouter} from "./routes/auth.js";
import {avatarRouter} from "./routes/avatar.js";
import {healthRouter} from "./routes/health.js";
import {profileRouter} from "./routes/profile.js";
import {subscriptionRouter} from "./routes/subscription.js";

export function createApp(context: GatewayContext): express.Express {
  const app = express();
  app.disable("x-powered-by");
  // Numeric hops, never `true`: with `true`, Express trusts the whole
  // X-Forwarded-For chain and a client-supplied leftmost entry would become the
  // rate-limit key. 0 (default) ignores forwarded headers entirely.
  app.set("trust proxy", context.config.trustProxyHops);

  app.use((_request, response, next) => {
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("Referrer-Policy", "no-referrer");
    response.setHeader("X-Frame-Options", "DENY");
    response.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
    next();
  });

  app.use((request, response, next) => {
    const startedAt = process.hrtime.bigint();
    response.setHeader("X-Request-Id", createRequestId());
    response.on("finish", () => {
      const durationMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
      // `baseUrl` carries the mount prefix for router-handled routes; without
      // it every mounted route logs as its relative path ("/signin").
      const fullPath = request.baseUrl + request.path;
      const route = fullPath.length > 120 ? fullPath.slice(0, 120) : fullPath;
      logRequest(
        {method: request.method, route, status: response.statusCode, durationMs},
        response.statusCode >= 400 ? "warn" : "info"
      );
    });
    next();
  });

  app.use(
    rateLimitMiddleware(
      new RateLimiter(context.config.rateLimit.windowMs, context.config.rateLimit.max),
      (request) => `all|${request.ip ?? "unknown"}`
    )
  );

  const authLimiter = new RateLimiter(
    context.config.rateLimit.windowMs,
    context.config.rateLimit.authMax
  );
  app.use(
    "/v1/auth/email",
    rateLimitMiddleware(authLimiter, (request) => `auth-email|${request.ip ?? "unknown"}`)
  );
  app.use(
    "/v1/auth/idp",
    rateLimitMiddleware(authLimiter, (request) => `auth-idp|${request.ip ?? "unknown"}`)
  );
  app.use(
    "/v1/auth/refresh",
    rateLimitMiddleware(authLimiter, (request) => `auth-refresh|${request.ip ?? "unknown"}`)
  );

  app.use(express.json({limit: context.config.bodyLimitBytes}));

  // Data-plane gate: without a resolved Admin credential every /v1 route would
  // fail anyway, and the Firestore/Storage clients leak a rejection while
  // loading missing Application Default Credentials. Refusing here is accurate
  // (503, retryable) and keeps the process alive to report readiness.
  app.use("/v1", (_request, response, next) => {
    if (context.credentialsReady) {
      next();
      return;
    }
    const error = new ApiError(
      "upstream-unavailable",
      "The relay is not ready: upstream credentials are unavailable."
    );
    response.status(error.status).json(errorBody(error));
  });

  app.use(healthRouter(context));
  app.use("/v1/auth", authRouter(context));
  app.use("/v1/account", accountRouter(context));
  app.use("/v1/profile", profileRouter(context));
  app.use("/v1/avatar", avatarRouter(context));
  app.use("/v1/subscription", subscriptionRouter(context));

  // One authenticated probe so clients can tell "the server is up" from
  // "this session is valid" without a data operation.
  app.get("/v1/session", requireAuth(context.auth), (request, response) => {
    response.json({authenticated: true, uid: request.gatewayUser?.uid ?? null});
  });

  app.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown route.");
    response.status(error.status).json(errorBody(error));
  });

  app.use((error: unknown, _request: Request, response: Response, _next: NextFunction) => {
    if (error instanceof ApiError) {
      response.status(error.status).json(errorBody(error));
      return;
    }
    const bodyParserError = mapBodyParserError(error);
    if (bodyParserError !== null) {
      response.status(bodyParserError.status).json(errorBody(bodyParserError));
      return;
    }
    // Malformed JSON bodies surface as SyntaxError from express.json.
    if (error instanceof SyntaxError) {
      const apiError = new ApiError("invalid-argument", "Malformed JSON body.");
      response.status(apiError.status).json(errorBody(apiError));
      return;
    }
    logError("unhandled gateway error", error);
    const apiError = new ApiError("internal", "The server could not complete the request.");
    response.status(apiError.status).json(errorBody(apiError));
  });

  return app;
}

export function buildContext(): GatewayContext {
  const config = loadConfig();
  const services = initFirebase(config);
  const callables = createCallableCaller({
    projectId: config.projectId,
    region: config.functionsRegion,
    apiKey: config.apiKey,
    upstreamTimeoutMs: config.upstreamTimeoutMs,
    auth: services.auth,
  });
  return {
    config,
    auth: services.auth,
    firestore: services.firestore,
    storage: services.storage,
    credential: services.credential,
    callables,
    credentialsReady: false,
  };
}

/**
 * Proves the Admin credential can mint a token before any request is allowed
 * to touch Firestore/Storage. The check itself is a promise we create and
 * handle with a timeout; the known-leaky SDK path is never entered when it
 * fails. Returns whether the credential resolved.
 */
export async function verifyStartupCredentials(context: GatewayContext): Promise<boolean> {
  try {
    await withTimeout(context.credential.getAccessToken(), context.config.upstreamTimeoutMs);
    context.credentialsReady = true;
    logEvent("upstream credentials resolved");
    return true;
  } catch (error) {
    logError(
      "upstream credentials unavailable; data plane disabled until restart",
      error
    );
    return false;
  }
}

export function startServer(context: GatewayContext): ReturnType<express.Express["listen"]> {
  const app = createApp(context);
  const server = app.listen(context.config.port, () => {
    logEvent("gateway listening", {port: context.config.port, region: context.config.functionsRegion});
  });
  // Node's own timeouts bound slow-loris style connections.
  server.requestTimeout = 30_000;
  server.headersTimeout = 20_000;
  server.keepAliveTimeout = 65_000;
  return server;
}
