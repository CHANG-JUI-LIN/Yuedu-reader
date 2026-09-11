import {randomUUID} from "node:crypto";

/**
 * Structured JSON logs with a deliberately small field set: a request id, the
 * route template, status and latency. Request bodies, Authorization headers,
 * passwords, ID/refresh tokens, Apple credentials and transaction JWTs must
 * never reach this logger.
 */
export interface RequestLogFields {
  method: string;
  route: string;
  status: number;
  durationMs: number;
}

export function createRequestId(): string {
  return randomUUID();
}

export function logRequest(fields: RequestLogFields, level: "info" | "warn" = "info"): void {
  const line = {
    severity: level === "warn" ? "WARNING" : "INFO",
    msg: "request",
    method: fields.method,
    route: fields.route,
    status: fields.status,
    durationMs: Math.round(fields.durationMs),
  };
  process.stdout.write(`${JSON.stringify(line)}\n`);
}

export function logEvent(msg: string, details: Record<string, string | number | boolean> = {}): void {
  process.stdout.write(`${JSON.stringify({severity: "INFO", msg, ...details})}\n`);
}

export function logError(msg: string, error: unknown): void {
  const message = error instanceof Error ? error.message : "unknown error";
  process.stderr.write(`${JSON.stringify({severity: "ERROR", msg, error: message})}\n`);
}
