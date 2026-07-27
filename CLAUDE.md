# table-client-apple

Spec-first repo. Before implementing anything, read in this order:

1. `DESIGN.md` (this repo) — the Apple-specific design (one SwiftUI codebase; iOS, iPadOS, and macOS destinations — not Catalyst).
2. `../DESIGN.md` (workspace root, one level up) — protocol and lifecycle (§1–§2) and the client conformance checklist (§3). Every transfer path must satisfy the checklist.
3. `../table-server/openapi.yaml` — the API contract; requests and parsing must match it exactly.

The spec wins over improvisation. If code and spec disagree, stop and reconcile the spec first.

## Implementation workflow

- `PROGRESS.md` is the plan of record. Work exactly one checkpoint per session, in order.
- A checkpoint is finished when its listed tests/scenarios pass locally **and** the comment sweep (see Code cleanliness) is done. Then: update `PROGRESS.md` (status + a dated log line), stage everything with `git add -A`, and **stop** — summarize what changed and wait for review.
- **Never `git commit`, never `git push`.** The user reviews the staged diff and commits.
- Do not start the next checkpoint in the same session unless the user says to continue.
- Blocked, or the code wants to deviate from the spec? Stop and ask; if agreed, change the spec first.

## Code cleanliness

- A comment must say something the code cannot: a spec constraint (cite it — "conformance rule 8", "root DESIGN §2 live relay"), a non-obvious why, or an invariant warning. If it narrates what the next line does, restates a name, or justifies the change to a reviewer ("this ensures…", "now correctly…"), it doesn't belong in the code.
- If a block needs a comment to explain *what* it does, extract it into a well-named function instead.
- Doc comments (`///`) on public `TableCore` API only, one line unless the behavior is genuinely subtle.
- No commented-out code, no section banners (`// MARK:` is fine sparingly in UI files), no TODOs that don't name a concrete follow-up (ideally a `PROGRESS.md` checkpoint).
- **After-done sweep**: before `git add`, re-read the full diff once looking only at comments; delete every one whose removal loses no information. This sweep is part of finishing a checkpoint, same as the tests.

## Non-negotiables (from the conformance checklist)

- Never ack a download that hasn't been fully length- and SHA-256-verified and fsynced.
- Resume, never restart: `HEAD` for the upload offset, `Range` from the partial file size. Background upload resume materializes a temp slice (see DESIGN.md §2).
- Download order: temp file → verify → fsync → **ack** → publish (Files app / `~/Downloads`).
- `404`/`410` on ack = success; `409` on ack = discard local copy and re-download.
- API key lives in the Keychain; attached to requests in exactly one place (`TableClient`).
- All logic lives in the `TableCore` package (no UI imports) so it runs under unit tests against a local `table-server`; the share extension never hashes or uploads.
