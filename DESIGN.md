# table-client-apple — design

One SwiftUI codebase, three destinations: **iPhone, iPadOS, macOS**. This is real multiplatform SwiftUI (separate iOS and macOS destinations of one app target), not Mac Catalyst — the Mac build is a fully native AppKit-backed app.

The wire protocol, lifecycle rules, and integrity guarantees live in the root `DESIGN.md` of the `table` project; this document covers only what is specific to the Apple client. Every transfer path here must satisfy the **client conformance checklist** in the root doc.

---

## 1. Project structure

```
table-client-apple/
  Table.xcodeproj
  TableCore/               # local Swift package — all logic, no UI
    Sources/TableCore/
      Api/                 # TableClient: typed wrapper over the HTTP API
      Transfer/            # queue, upload/download tasks, resume logic
      Crypto/              # streaming SHA-256 (CryptoKit)
      Settings/            # host URL + API key persistence
  Table/                   # app target (iOS + iPadOS + macOS destinations)
    App/                   # entry point, DI wiring
    Screens/               # MainView, SettingsView
    Platform/              # per-platform glue behind #if os(...)
  ShareExtension/          # iOS share-sheet extension target
```

`TableCore` is UI-free and fully testable off-device; the app target and the share extension both depend on it. Platform divergence stays in `Platform/` and `#if os(macOS)` blocks — the screens themselves are shared.

## 2. Networking

`URLSession` throughout, with two distinct configurations:

- **Foreground transfers** (app active, macOS always): a plain `URLSession` with streamed upload bodies. Uploads seek the source file to the resume offset and stream a `PATCH`; downloads stream to a temp file while a `SHA256` hash is updated incrementally.
- **Background transfers** (iOS/iPadOS): a background `URLSessionConfiguration` so transfers survive suspension and app termination. Two protocol-imposed wrinkles, handled honestly rather than papered over:
  - Background *upload* tasks must upload from a file, front to back. The common case (fresh upload, offset 0) maps directly onto one `PATCH` of the whole file. Resuming from a non-zero offset means materializing the remainder as a temp slice file first — acceptable, since resume-after-failure is the rare path. (Files land in the app group container; slices are deleted on task completion.)
  - Background *download* tasks deliver a finished temp file rather than a stream, so hashing happens after completion instead of incrementally. That's fine — verification is about the complete file anyway. Manual `Range` resume: keep the partial file, issue a ranged request, append. Use `resumeData` when URLSession offers it, fall back to explicit `Range` when it doesn't.

The `Authorization` header is attached by the `TableClient` layer, never scattered through call sites.

## 3. Transfer queue

- Persistent queue table (SQLite via GRDB). On iOS/iPadOS it lives in the **app group container** so the share extension and the main app see the same queue; macOS has no extension to share it with and keeps it in the app's own container. Two processes on one SQLite file means WAL mode and a busy timeout, and it means the app re-reads the queue when it comes to the front: database observation does not cross process boundaries.
- States: `queued → running → verifying → done | failed(retryable) | failed(permanent)`.
- Concurrency cap: 2 uploads / 2 downloads. Exponential backoff on retryable failures; resume via `HEAD` (uploads) or `Range` (downloads) rather than restarting.
- Download completion order (conformance rule): temp file fully written in app container → verify length + SHA-256 → **ack** → then publish to its final destination. Publish failure never loses data — the verified temp file is still on disk.
  - iOS/iPadOS: publish = save into the app's Documents directory, exposed to the Files app (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`), with an optional "export…" action (share sheet) for a user-chosen location.
  - macOS: publish = move to `~/Downloads`.

## 4. Platform integrations

**iOS / iPadOS**
- **Share extension**: `ACTION_SEND` equivalent — accepts any file types, multi-select. An extension lives only as long as its UI, so it does no hashing and no uploading: it copies the incoming items into the app group container, appends queue rows, and confirms. The main app hashes and uploads when it is next opened. It cannot be otherwise: conformance rule 1 requires the whole file's SHA-256 *before* `POST /uploads`, so there is no transfer for the extension to start — not even a background one — until a full pass over a possibly multi-GB file has happened somewhere that is allowed to take that long. UI is a minimal "queued ✓" confirmation that says the app has to be opened.
- **Document picker** in-app for multi-select uploads from Files.
- **Local notifications** on transfer completion/failure while backgrounded.
- iPad is the same app with a wider layout (`NavigationSplitView`: file list + queue side by side).

**macOS**
- Drag-and-drop onto the main window and onto the Dock icon. The Dock only delivers a drop for a type the app claims it opens, so the macOS build declares `CFBundleDocumentTypes` for `public.data` at `LSHandlerRank = None` — a drop target, never the default handler for anything — and `LSSupportsOpeningDocumentsInPlace`, which is what it does: the original file is bookmarked and read where it lies, never copied in.
- **Menu bar extra**: a drop target that enqueues uploads without the main window, plus a glanceable list of server files with one-click download.
- Standard user notifications on completion.
- Login item optional (settings toggle) so the menu bar extra is always available. A launch with no window restored is the case the app has to survive: the queue resumes from the app delegate, not from a screen appearing.

## 5. Screens

Same two-screen shape as the Android client:

1. **Main** — server file list (poll ~5 s while foregrounded; entries show name, size, expiry countdown, and upload progress for `uploading` files, which are downloadable immediately per the live-relay design) + local transfer queue with per-item progress. "Download all" action.
2. **Settings** — host URL, API key, "test connection". URL in `UserDefaults` — on iOS/iPadOS the app group's suite, which is how the share extension can tell the user the app has no server yet before it queues anything. The key is not shared: the extension never talks to the server, so it has no use for one.

   The API key goes in the **Keychain on iOS/iPadOS** and in a `0600` file in the container **on macOS**. macOS pins a file-keychain item's ACL to the app's designated requirement, which for a locally signed build is its `cdhash`, so every rebuild reads as a new app and the system demands the login password again; the data-protection keychain would not ask but needs an `application-identifier` entitlement no ad-hoc signature can carry. A local build that prompts on every launch is worse than a key at rest in a container the sandbox already guards, and the files this app moves are ephemeral. Revisit if macOS builds are ever signed with a team.

## 6. Apple-specific edge cases

| Situation | Handling |
|---|---|
| App suspended mid-transfer (iOS) | Background URLSession continues; completion handler re-launches the app to run verify → ack. |
| Share extension killed for memory | It only ever copies files + writes queue rows — nothing to lose; main app picks the queue up. |
| Background upload needs non-zero offset | Materialize remainder slice in app group tmp, upload that, delete slice. |
| User force-quits the app | Background tasks die with it (OS behavior); queue rows persist and resume on next launch via `HEAD`/`Range`. |
| Ack succeeded but publish to Files failed | Verified temp file retained; publish retried; surfaced in queue as actionable error. |

## 7. Testing

Automation lives where the correctness risk lives — `TableCore` — and nowhere else.

- **Conformance integration tests** (the core suite): XCTest targets in the `TableCore` package that re-run the server's conformance scenarios through the real client code against a local `table-server` (`TABLE_URL`/`TABLE_API_KEY` from the environment; tests skip with a clear message when no server is up). Roundtrip, upload resume, Range resume, hash-mismatch handling, ack semantics including 404-means-success — the same list as `table-server/conformance/scenarios/`.
- **Fault-path tests**: run the dev server with `TABLE_TEST_FAULTS=1` and use `X-Test-Drop-After` to cut the connection at an exact byte in both directions. Asserts resume from the committed offset / partial-file size, never a restart. These run against the *foreground* URLSession path, which shares all logic with the background path except the session configuration.
- **Unit tests** for the pure logic: rebuilding the SHA-256 digest from a partial temp file, queue state transitions, temp-slice creation for background upload resume, collision-safe naming.
- **Background URLSession is verified manually**, once per release, on a device: start a large transfer, background the app, confirm completion → verify → ack. The scheduling machinery itself isn't meaningfully unit-testable; everything it calls into is covered above.
- **No XCUITest.** Two screens, one user. Share extension intake and Files/`~/Downloads` publish are part of the manual release pass.

## 8. Build order

1. `TableCore`: API client + hashing + queue, with unit tests against a local `table-server`.
2. macOS destination first (fastest iteration loop, no provisioning friction): main window, settings, drag-and-drop, foreground transfers.
3. iOS destination: same screens, background sessions, notifications.
4. Share extension + app group plumbing.
5. Menu bar extra, Dock drop, iPad layout polish.
