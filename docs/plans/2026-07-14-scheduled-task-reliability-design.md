# Scheduled Task Reliability Design

## Outcome

Scheduled tasks must continue working when OpenCode credentials are rotated, must not replay obsolete queued work after downtime, and must appear exactly once in the iOS Regular Tasks list. A create request must also be safe when a response is lost or a user retries.

## Daemon design

`OpenCodeClient` will retain its environment-file source when created through `from_environment`. If OpenCode returns `401`, the client will reload the current environment file and retry that rejected request once. This is safe for POST requests because OpenCode rejects the request during HTTP authentication before executing it.

Pending runs represent short transient contention, not durable historical work. The store will keep at most one pending run per scheduled task and discard pending entries older than one hour, entries for missing tasks, and entries for disabled tasks. Cleanup runs during scheduler startup before jobs are restored. This removes the existing June backlog without deleting current task schedules.

Task creation will carry a stable `client_task_id`. The daemon will return the existing task when it receives the same client id for the same agent and project, making create idempotent. The serialized task payload will return that id so the app can reconcile a remote task after a lost response.

## iOS design

Regular Tasks will use one automatic refresh trigger and a single-flight guard for pull, push, and lifecycle refreshes. During reconciliation, local rows will be grouped by remote id; one canonical row is retained and all extra SwiftData rows are deleted. A remote record with `client_task_id` will bind to the corresponding unsynced local row before the importer considers inserting a new row.

Task payloads will include the local model UUID as `client_task_id`. New task POSTs will not receive the generic transport retry used for idempotent updates. Existing daemon versions remain safe because they ignore the extra field, while updated daemons use it for idempotency.

## Recovery and rollout

The daemon tests will cover credential rotation, pending-run expiry/coalescing, and idempotent create. iOS tests will cover client id payload/parsing and pure reconciliation selection where practical. After focused tests and the repository CI pass, the daemon will be deployed to the test server. Startup cleanup will discard the 23 stale June pending runs, preserve the five schedules, and allow the overdue one-shot to run once with current OpenCode credentials.

The app will pin the fixed daemon commit so updated clients repair their managed servers automatically. Shipping the iOS build remains the client-wide distribution step.
