import {Router, raw} from "express";

import {authenticatedUser, requireAuth} from "../auth.js";
import type {GatewayContext} from "../context.js";
import {ApiError, errorBody} from "../errors.js";
import {avatarObjectPath} from "../policy.js";
import {logError} from "../logger.js";

const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff]);

export function avatarRouter(context: GatewayContext): Router {
  const router = Router();
  const maxBytes = context.config.avatarMaxBytes;

  /**
   * Serves the signed-in user's own avatar bytes. Read access is authenticated:
   * the previous public Storage URL is exactly what Chinese devices cannot
   * fetch, and a redirect would just re-expose the unreachable host.
   */
  router.get("/", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const file = context.storage.bucket().file(avatarObjectPath(user.uid));
      const [exists] = await file.exists();
      if (!exists) {
        const error = new ApiError("not-found", "No avatar has been uploaded.");
        response.status(error.status).json(errorBody(error));
        return;
      }
      const [metadata] = await file.getMetadata();
      const [bytes] = await file.download();
      const etag = typeof metadata.etag === "string" ? metadata.etag : String(metadata.md5Hash ?? "");
      response.setHeader("Content-Type", "image/jpeg");
      response.setHeader("Cache-Control", "private, max-age=300");
      if (etag !== "") response.setHeader("ETag", etag);
      response.send(bytes);
    } catch (error) {
      next(error);
    }
  });

  router.put(
    "/",
    requireAuth(context.auth),
    raw({type: ["image/jpeg", "image/png", "application/octet-stream"], limit: maxBytes}),
    async (request, response, next) => {
      try {
        const user = authenticatedUser(request);
        const body: unknown = request.body;
        if (!Buffer.isBuffer(body) || body.length === 0) {
          throw new ApiError("invalid-argument", "An image body is required.");
        }
        if (body.length > maxBytes) {
          throw new ApiError("payload-too-large", "The avatar exceeds the size limit.");
        }
        if (!body.subarray(0, 3).equals(JPEG_MAGIC)) {
          throw new ApiError("unsupported-media-type", "The avatar must be a JPEG image.");
        }
        const file = context.storage.bucket().file(avatarObjectPath(user.uid));
        await file.save(body, {
          contentType: "image/jpeg",
          resumable: false,
          metadata: {cacheControl: "private, max-age=300"},
        });
        const [metadata] = await file.getMetadata();
        const version = typeof metadata.etag === "string" ? metadata.etag : String(Date.now());
        const photoURL = `${context.config.publicBaseUrl}/v1/avatar?v=${encodeURIComponent(version)}`;
        await context.firestore.collection("users").doc(user.uid).set(
          {photoURL, updatedAt: new Date()},
          {merge: true}
        );
        response.json({photoURL});
      } catch (error) {
        next(error);
      }
    }
  );

  router.delete("/", requireAuth(context.auth), async (request, response, next) => {
    try {
      const user = authenticatedUser(request);
      const file = context.storage.bucket().file(avatarObjectPath(user.uid));
      try {
        await file.delete({ignoreNotFound: true});
      } catch (error) {
        logError("avatar delete failed", error);
        throw new ApiError("upstream-unavailable", "The avatar could not be removed. Try again.");
      }
      await context.firestore.collection("users").doc(user.uid).set(
        {photoURL: "", updatedAt: new Date()},
        {merge: true}
      );
      response.json({deleted: true});
    } catch (error) {
      next(error);
    }
  });

  router.use((_request, response) => {
    const error = new ApiError("not-found", "Unknown avatar route.");
    response.status(error.status).json(errorBody(error));
  });

  return router;
}
