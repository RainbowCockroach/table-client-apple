# Progress — table-client-apple

Plan of record for implementation sessions. Working rules are in `CLAUDE.md`:
one checkpoint at a time → tests green → update this file → `git add -A` →
**stop for review. Never commit, never push.**

Prerequisite: a working `table-server` (local dev build is enough).

| # | Checkpoint | Proves | Status |
|---|---|---|---|
| C1 | `TableCore` package: API client + hashing + queue, XCTest conformance-scenario tests against a local server (incl. fault-path tests via `X-Test-Drop-After`) | conformance + fault tests green | done |
| C2 | macOS destination: main window, settings, drag-and-drop, foreground transfers end-to-end | manual: drop → upload → download on another device | staged for review |
| C3 | iOS destination: same screens, background `URLSession` transfers, notifications | manual background-transfer pass (DESIGN.md §7) | not started |
| C4 | Share extension + app group plumbing | manual: share from Photos/Files → queued → uploaded | not started |
| C5 | Menu bar extra, Dock drop, iPad layout polish | manual release pass | not started |

Distribution is manual (Xcode / TestFlight) — no release CI planned for this repo.

Status values: `not started` → `in progress` → `staged for review` → `done` (user committed).

## Log

*(append one dated line per session)*

- **2026-07-30 — C1 `TableCore` staged.** New local Swift package (`swift-tools 6.0`, iOS 17 /
  macOS 14, one dependency: GRDB 7 for the queue per DESIGN §3). `Crypto/` (incremental
  CryptoKit SHA-256, the 1 MiB transfer buffer, digest-rebuild-from-partial). `Api/`
  (`TableClient` covering all eight contract operations, `Models`, `TableError` +
  `RetryPolicy`, `DownloadStream`, and the URLSession streaming plumbing: `BodyChannel` +
  `TaskDelegates`). `Transfer/` (`Downloader`, `Uploader`, `UploadSource`, `DownloadTask`/
  `UploadTask` behind a `TransferAttempt` seam, `DirectoryDownloadPublisher` + `DisplayNames`,
  `TransferRecord`/`TransferStore`/`SQLiteTransferStore`, and the `TransferQueue` actor:
  2 transfers per direction, exponential backoff, resume-on-launch). **42 XCTest tests green**
  against a dev server (`TABLE_TTL=5s`, `TABLE_TEST_FAULTS=1`), three runs clean: conformance
  scenarios 01–10 through the real client code, a queue round-trip suite end to end, plus unit
  tests for hashing, display names, publish ordering, the SQLite store and the queue's state
  machine. Without `TABLE_URL`/`TABLE_API_KEY` the 18 server tests skip with a message and the
  24 unit tests still run. `README.md` gained the layout and dev loop.
  **Reviewer, judgement calls:** (1) The Xcode project is untouched — the app target picks the
  package up in C2, where there is UI to build against it. (2) `TableClient` carries one
  internal seam, `WireHook`, because `Range`/`Upload-Offset` are only observable on the wire;
  the tests reach it through `@testable import` and nothing in the app installs one.
  (3) Foreground uploads seek the source file (`InputStream` + `fileCurrentOffsetKey`) rather
  than materializing a slice, per DESIGN §2; the body is one-shot, so URLSession cannot replay
  a dropped `PATCH` from a stale offset (rule 2). (4) Scenario 10's download half asserts that
  the resume starts from whatever landed, not from the exact armed byte count: the server's
  abrupt close resets the connection and an RST lets the receiver discard buffered-but-
  undelivered bytes, so the exact figure is not ours to promise. The upload half is still
  byte-exact, since there the server reports its own committed offset.
  **Two things for you, not code in this repo:**
  - **Server race, live relay vs. ack.** `tailReader.Read` returns EOF as soon as `pos >= size`,
    and `relayedWriter` publishes the last chunk *before* `finalize()` rehashes, renames and
    flips the row to `available`. So a fast live-relay downloader legitimately holds the whole
    verified file while the row still says `uploading`, and `handleAck` answers `404` to
    anything not `available`. The client is conformant either way — rule 9 makes `404` a
    success — but the file is then *not* deleted and lives out its TTL, which is the one
    property the ack exists to provide. It reproduces on localhost with a 2 MiB file (scenario
    08); root DESIGN §2's "ack before finalize is impossible by construction" is what needs
    revisiting. Tightest fix looks like holding the relay reader's final EOF until the
    finalize signal. `table-client-android`'s scenario 08 asserts `DELETED`, so it has the
    same latent flake.
  - **iOS destination not compiled here.** Only the macOS platform is installed in this Xcode,
    so `swift test` covers macOS only. `TableCore` imports nothing but Foundation, CryptoKit
    and GRDB, but the iOS build is unverified until `xcodebuild -downloadPlatform iOS` has run.

- **2026-07-31 — C2 macOS destination staged.** `TableCore` gained the `Settings/` module DESIGN §1
  called for: `TableSettings` (host URL, key, insecure-http override, and the one place a client
  is built from them), `SettingsStore` (URL in `UserDefaults`, key in the Keychain) and
  `KeychainAPIKeyStore` (data-protection keychain, `AfterFirstUnlock` because C3 transfers run
  locked, and an `accessGroup` for C4's extension). `UploadSource` now refuses folders and empty
  files — `POST /uploads` rejects a non-positive size, so that belongs in tested code rather than
  in UI glue. **52 XCTest tests green** (the 42 from C1 plus 6 settings and 4 upload-source),
  run against a dev server with `TABLE_TTL=5s TABLE_TEST_FAULTS=1`.
  The Xcode project picks `TableCore` up as a local package, and the Downloads-folder
  entitlement arrives through `ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER[sdk=macosx*] = readwrite`.
  The app target is now `App/` (entry point, `AppContainer` + `ClientProvider`, the observable
  `AppModel`), `Screens/` (`MainView`: server list with expiry countdowns and live upload
  progress, transfer queue with progress/retry/dismiss, "Take all"; `SettingsView` with
  test-connection) and `Platform/` (`AppPaths`, `UploadIntake`, `SourceBookmarks`).
  **Verified here:** both destinations build (`platform=macOS` and `generic/platform=iOS Simulator`
  — which closes C1's open question about the iOS build), and the sandboxed app launches, wires
  its container up and creates `queue.sqlite` in it. **Not verified here:** the drop → upload →
  download pass itself. Driving the UI needs Accessibility permission for the terminal, which
  this session does not have, so the checkpoint's manual proof is still yours to run.
  **Reviewer, judgement calls:** (1) The queue lives in Application Support, not an app group:
  the group entitlement needs provisioning and nothing shares the queue until C4. Every path is
  in `AppPaths`, so that move is one edit. (2) macOS sandbox vs. rule 14: a dropped or picked
  file is readable only while the app holds a claim on it, and the claim dies with the process —
  so the intake bookmarks each source and `AppModel.start()` reopens the claims before
  `resumeUnfinished()`. Claims are held for the whole launch rather than balanced, because a
  queued upload may start reading at any point until it finishes. (3) Intake is macOS-only; the
  iOS half is the document picker (C3) and the share extension (C4), so the iOS build compiles
  and shows the list and queue with no add affordance. (4) The list polls only while
  `scenePhase == .active`, matching the Android client — with another app focused the server
  list goes stale, while transfer rows keep updating from the queue's own stream.
  (5) No completion notifications yet (DESIGN §4); they are one piece of work with the iOS ones
  in C3. (6) The C1 note about the server's live-relay/ack race is still open and untouched here.
