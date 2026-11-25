# Changelog

## 0.2.0

Added, with everything in 0.1.0 unchanged:

- `createJob` (JSON jobs, with an `Idempotency-Key`), `createBatch`, `getJob`,
  `listJobs`, `downloadOutput(_:index:)` for multi-output jobs, and
  `waitForJob`, which returns the job and its `outputs`.
- Designs: `compileDesign`, `renderDesign`.
- Direct uploads: `upload` from bytes or a file (read a chunk at a time),
  `getAsset`, `deleteAsset`.
- `operations`, `usage` (with `groupBy`), `deleteEndUser`, `createEmbedToken`.
- Storage destinations: list, create, get, update, delete, test, presign.
- Webhook endpoints: list, create, get, update, delete, rotate, deliveries,
  test; and `SnappedCut.verifyWebhook`, with HMAC-SHA256 in plain Swift so it
  runs on Linux with no dependency.
- `SnappedCutError.code`, `isOutOfCredits` and `isRateLimited`.
- `Job.outputs`, and the `Created`, `Asset`, `JobOutput`, `WebhookEndpoint`,
  `StorageDestination` and `JSONValue` types.
- User-Agent is `snappedcut-swift/0.2.0`.

## 0.1.0 — first release
