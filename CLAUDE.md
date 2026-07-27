# table-client-apple

Spec-first repo. Before implementing anything, read in this order:

1. `DESIGN.md` (this repo) — the Apple-specific design (one SwiftUI codebase; iOS, iPadOS, and macOS destinations — not Catalyst).
2. `../DESIGN.md` (workspace root, one level up) — protocol and lifecycle (§1–§2) and the client conformance checklist (§3). Every transfer path must satisfy the checklist.
3. `../table-server/openapi.yaml` — the API contract; requests and parsing must match it exactly.

The spec wins over improvisation. If code and spec disagree, stop and reconcile the spec first.

## Implementation workflow

- `PROGRESS.md` is the plan of record. Work exactly one checkpoint per session, in order.
- A checkpoint is finished when its listed tests/scenarios pass locally. Then: update `PROGRESS.md` (status + a dated log line), stage everything with `git add -A`, and **stop** — summarize what changed and wait for review.
- **Never `git commit`, never `git push`.** The user reviews the staged diff and commits.
- Do not start the next checkpoint in the same session unless the user says to continue.
- Blocked, or the code wants to deviate from the spec? Stop and ask; if agreed, change the spec first.

## Non-negotiables (from the conformance checklist)

- Never ack a download that hasn't been fully length- and SHA-256-verified and fsynced.
- Resume, never restart: `HEAD` for the upload offset, `Range` from the partial file size. Background upload resume materializes a temp slice (see DESIGN.md §2).
- Download order: temp file → verify → fsync → **ack** → publish (Files app / `~/Downloads`).
- `404`/`410` on ack = success; `409` on ack = discard local copy and re-download.
- API key lives in the Keychain; attached to requests in exactly one place (`TableClient`).
- All logic lives in the `TableCore` package (no UI imports) so it runs under unit tests against a local `table-server`; the share extension never hashes or uploads.
