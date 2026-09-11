import {readFileSync} from "node:fs";

/**
 * All configuration comes from the environment. Nothing here is a secret
 * default: a missing required value fails startup instead of silently serving
 * broken traffic.
 */
export interface GatewayConfig {
  port: number;
  projectId: string;
  /** Public Firebase Web API key (the `API_KEY` from GoogleService-Info.plist). */
  apiKey: string;
  storageBucket: string;
  functionsRegion: string;
  /** Absolute public base URL, used to build avatar URLs handed to the client. */
  publicBaseUrl: string;
  /**
   * Number of trusted reverse-proxy hops in front of this process. 0 (default)
   * ignores X-Forwarded-For entirely; 1 matches one Caddy/nginx hop. Express
   * then takes the rightmost untrusted entry, so extra entries a client stuffed
   * into the header cannot become the rate-limit key.
   */
  trustProxyHops: number;
  serviceAccountJson: string | null;
  rateLimit: {
    windowMs: number;
    max: number;
    authMax: number;
  };
  upstreamTimeoutMs: number;
  bodyLimitBytes: number;
  avatarMaxBytes: number;
}

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (value === undefined || value === "") {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value;
}

function optional(name: string, fallback: string): string {
  const value = process.env[name]?.trim();
  return value === undefined || value === "" ? fallback : value;
}

function integer(name: string, fallback: number): number {
  const raw = process.env[name]?.trim();
  if (raw === undefined || raw === "") return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`Environment variable ${name} must be a non-negative integer`);
  }
  return parsed;
}

export function loadConfig(): GatewayConfig {
  const projectId = required("FIREBASE_PROJECT_ID");
  const serviceAccountJson = readServiceAccountJson();
  return {
    port: integer("PORT", 8080),
    projectId,
    apiKey: required("FIREBASE_API_KEY"),
    storageBucket: optional("FIREBASE_STORAGE_BUCKET", `${projectId}.firebasestorage.app`),
    functionsRegion: optional("FUNCTIONS_REGION", "asia-east1"),
    publicBaseUrl: required("PUBLIC_BASE_URL").replace(/\/+$/, ""),
    trustProxyHops: integer("TRUST_PROXY_HOPS", 0),
    serviceAccountJson,
    rateLimit: {
      windowMs: integer("RATE_LIMIT_WINDOW_MS", 60_000),
      max: integer("RATE_LIMIT_MAX", 120),
      authMax: integer("RATE_LIMIT_AUTH_MAX", 20),
    },
    upstreamTimeoutMs: integer("UPSTREAM_TIMEOUT_MS", 15_000),
    bodyLimitBytes: integer("BODY_LIMIT_BYTES", 64 * 1024),
    avatarMaxBytes: integer("AVATAR_MAX_BYTES", 2 * 1024 * 1024),
  };
}

/**
 * Service-account credentials are accepted either as an inline JSON string
 * (base64 or raw, for secret managers) or via GOOGLE_APPLICATION_CREDENTIALS,
 * which the Admin SDK reads itself. The value never gets logged.
 */
function readServiceAccountJson(): string | null {
  const inline = process.env.FIREBASE_SERVICE_ACCOUNT_JSON?.trim();
  if (inline === undefined || inline === "") return null;
  if (inline.startsWith("{")) return inline;
  const decoded = Buffer.from(inline, "base64").toString("utf8");
  if (!decoded.trimStart().startsWith("{")) {
    throw new Error("FIREBASE_SERVICE_ACCOUNT_JSON is neither raw JSON nor base64 JSON");
  }
  return decoded;
}

export function assertServiceAccountPathReadable(): void {
  const path = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  if (path === undefined || path.trim() === "") return;
  readFileSync(path);
}
