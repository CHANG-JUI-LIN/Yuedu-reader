import type {NextFunction, Request, Response} from "express";

import {ApiError, errorBody} from "./errors.js";

interface Bucket {
  count: number;
  resetAt: number;
}

/**
 * Small fixed-window limiter. This is process-local: run a single gateway
 * instance per region, or accept that the effective limit is
 * `instances × max`. A shared store is only worth adding once the deployment
 * scales horizontally.
 */
export class RateLimiter {
  private readonly buckets = new Map<string, Bucket>();

  constructor(
    private readonly windowMs: number,
    private readonly max: number
  ) {}

  /** Returns seconds until the window resets when the request must be refused. */
  consume(key: string, now: number = Date.now()): number | null {
    const existing = this.buckets.get(key);
    if (existing === undefined || existing.resetAt <= now) {
      this.buckets.set(key, {count: 1, resetAt: now + this.windowMs});
      return null;
    }
    if (existing.count >= this.max) {
      return Math.max(1, Math.ceil((existing.resetAt - now) / 1000));
    }
    existing.count += 1;
    return null;
  }

  /** Drops expired buckets so a long-lived process does not grow unbounded. */
  prune(now: number = Date.now()): void {
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAt <= now) this.buckets.delete(key);
    }
  }
}

export function rateLimitMiddleware(
  limiter: RateLimiter,
  bucket: (request: Request) => string
): (request: Request, response: Response, next: NextFunction) => void {
  return (request, response, next) => {
    const retryAfter = limiter.consume(bucket(request));
    if (retryAfter !== null) {
      response.setHeader("Retry-After", String(retryAfter));
      const error = new ApiError("rate-limited", "Too many requests. Try again shortly.");
      response.status(error.status).json(errorBody(error));
      return;
    }
    next();
  };
}
