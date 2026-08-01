# Progress — table-client-apple

Plan of record for implementation sessions. Working rules are in `CLAUDE.md`:
one checkpoint at a time → tests green → update this file → `git add -A` →
**stop for review. Never commit, never push.**

Prerequisite: a working `table-server` (local dev build is enough).

| # | Checkpoint | Proves | Status |
|---|---|---|---|
| C1 | `TableCore` package: API client + hashing + queue, XCTest conformance-scenario tests against a local server (incl. fault-path tests via `X-Test-Drop-After`) | conformance + fault tests green | done |
| C2 | macOS destination: main window, settings, drag-and-drop, foreground transfers end-to-end | manual: drop → upload → download on another device | done |
| C3 | iOS destination: same screens, background `URLSession` transfers, notifications | manual background-transfer pass (DESIGN.md §7) | done |
| C4 | Share extension + app group plumbing | manual: share from Photos/Files → queued → uploaded | done |
| C5 | Menu bar extra, Dock drop, iPad layout polish | manual release pass | staged for review |

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

- **2026-07-31 — C3 iOS destination staged.** The transfer code grew one seam per direction so
  the same conformance logic runs over either session (DESIGN §2): `DownloadFetcher`
  (`StreamingDownloadFetcher` / `BackgroundDownloadFetcher`) and `UploadSender`
  (`StreamingUploadSender` / `BackgroundUploadSender`, which materializes the resume slice).
  `Downloader`/`Uploader` keep verify, ack, publish and rule 2/3 handling; only the bytes move
  differently. New `BackgroundTransferSession` wraps the background `URLSession`: tasks are
  labelled through `taskDescription` — the only state the system keeps for us — so a relaunched
  app adopts a running task instead of sending the same bytes twice, and an event that arrives
  with nobody waiting is held for the attempt that comes asking. A delivered download is
  appended to its partial file *in the delegate* (`applyDownloadedTail`, which checks rule 6's
  declarations first and moves rather than copies when the response starts at byte 0), so the
  tail lands whether or not this process is still there; the hash is then computed over the
  whole partial file, which is what the streaming path's incremental digest was for.
  `TableClient` gained `appendWholeFile(…via:)` and `download(_:via:)` so requests and responses
  are still built and read in exactly one place (rule 12), with the transports as dumb pipes.
  App side: `.backgroundTask(.urlSession(…))` finishes woken transfers (`resumeUnfinished` →
  `drain`), the document picker is now the shared intake (iOS copies the pick into the container
  first, and `UploadTask` owns those copies — deleted on finalize, dismiss and launch sweep),
  downloads land in Documents with `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
  and a share-sheet export, and `TransferNotifications` posts one notification per settled
  transfer on both platforms. **62 XCTest tests green** (the 52 from C2 plus 7 unit tests for the
  slice and the tail-append, and 3 server-backed round-trips driven through the background seams),
  three runs clean against a dev server with `TABLE_TTL=5s TABLE_TEST_FAULTS=1`.
  **Verified here:** both destinations build; the iOS app installs and launches on the simulator,
  sets up the background session, excludes the container from backup and creates `queue.sqlite`;
  the macOS Release build is installed in `/Applications` and launches. **Not verified here:**
  the manual background pass of DESIGN §7 (start a large transfer, background the app, confirm
  completion → verify → ack) — that needs a device and hands on the UI, and the API key can only
  be typed in, so the end-to-end pass is still yours to run.
  **Reviewer, judgement calls:** (1) DESIGN §3 named `UISupportsDocumentBrowser` for the Files
  app; that key is for apps rooted in a document browser, so the spec now names the two keys a
  plain app needs — the design doc was changed first, per the workflow. (2) The iOS intake copies
  the picked file into the container instead of bookmarking it in place, because `nsurlsessiond`
  reads the body out of process and the pick's claim dies with the launch; that is the same move
  DESIGN §4 already specifies for the share extension, so C4 inherits it. (3) The background
  session is a global in `AppContainer.swift`: one per identifier per process is a `URLSession`
  rule, and SwiftUI may evaluate `@State private var model = AppModel()` more than once. (4) The
  progress a background download reports is `resumeOffset + bytes written`, which is the file's
  size on disk, not the server's committed figure — same convention as the streaming path.
  (5) Rule 7 for the moved-in case: the file is opened and `synchronize()`d after the move, since
  a rename promises nothing about the bytes. (6) `drain()` on the wake path waits for retry
  backoff too; the system suspends us when our time is up and the queue resumes at next launch.
  (7) The C1 note about the server's live-relay/ack race is still open and untouched here.
  **Fix found by running the installed app:** saving the API key failed on macOS with
  `errSecMissingEntitlement` — C2's `KeychainAPIKeyStore` asks for the data-protection keychain,
  which macOS opens only to an app signed with a team, and there is no signing identity on this
  machine. `KeychainAPIKeyStore` now falls back to the macOS file keychain when a write is
  refused, and reads try the data-protection keychain first and the file one after: a signed
  build behaves exactly as DESIGN §5 says, an ad-hoc one keeps working, and a build that gains a
  team later finds the key the earlier one left. Measured rather than assumed — an ad-hoc test
  binary showed that only the writes report the missing entitlement, while a read of the
  data-protection keychain answers `errSecItemNotFound`, so a probe-once-then-choose design would
  have written to one keychain and read from the other. The file keychain ties an item to the
  binary's signature, so an ad-hoc build may ask for keychain permission again after a rebuild;
  signing in to Xcode with an Apple ID (needed for a device anyway) avoids both.

- **2026-07-31 — C4 share extension + app group staged.** Three spec points were reconciled first,
  per the workflow. DESIGN §4 had the extension starting a background session; it cannot —
  conformance rule 1 wants the whole file's SHA-256 before `POST /uploads`, so there is no
  transfer to start until something with time to spare has read a possibly multi-GB file. The
  extension now stages and queues, and the app sends. §3 gained the two consequences of one
  SQLite file with two processes on it (WAL + busy timeout; observation does not cross a process
  boundary, so the app re-reads the queue when it comes to the front) and says the group is
  iOS-only. §5 says the host URL moves to the group's defaults suite and the API key stays put:
  the extension never talks to the server.
  New in `TableCore`: `Settings/ContainerPaths.swift` (`AppGroup` — the identifier, its defaults
  suite and its container — and `ContainerPaths`, every path inside the container resolved the
  same way by both processes) and `Transfer/UploadStaging.swift`, which is the extension's whole
  job: copy the item in, append the row, and drop the copy if the row cannot be written. The
  copy and the row halves are callable separately because a shared item is readable only inside
  the callback that hands it over, and that callback cannot wait for a database write. Also
  `TransferRecord.upload(…)` (one definition of an upload row, whichever process appends it),
  `TransferQueue.pickUpQueuedWork()`, `SettingsStore(inheritingFrom:)` + `hasHost(in:)`, and
  `SQLiteTransferStore` on a `DatabasePool` — WAL, a 10 s busy timeout, and open-and-migrate
  inside an `NSFileCoordinator` block, per GRDB's own guide for a shared database.
  New target `ShareExtension/`: `ShareViewController` hosting a SwiftUI confirmation, and
  `SharedItemsIntake`, which resolves each `NSItemProvider` to a file and stages it. Activation
  takes files, images and movies, up to 20 at a time. App side: `AppPaths` splits into the shared
  container and the publish directory, the iOS picker now goes through the same `UploadStaging`
  the extension uses, the background session is told the shared container identifier, and
  `MainView` calls `AppModel.adoptSharedQueue()` when the scene becomes active.
  **72 XCTest tests green** (the 62 from C3 plus 6 for staging, 3 for the settings suite move and
  the keyless host check, and one that drives two store connections at the same file the way the
  two processes do), three runs clean against a dev server with `TABLE_TTL=5s TABLE_TEST_FAULTS=1`.
  **Verified here:** both destinations build; the iOS app installs on the simulator, launches and
  creates `queue.sqlite` (with its `-wal`/`-shm`) in the *group* container; `pluginkit` lists
  `rainbowroachie.Table.ShareExtension` as registered, and both binaries carry the
  `application-groups` entitlement; the macOS Release build is installed in `/Applications`,
  launches, and is untouched by all of this — same container, same entitlements, no `PlugIns`.
  **Not verified here:** the share sheet pass itself (share from Photos/Files → queued → open the
  app → uploaded). Driving the simulator's UI needs Accessibility permission this session does
  not have, so that manual proof is yours.
  **Reviewer, judgement calls:** (1) macOS keeps its own container: nothing shares its queue, and
  a group identifier there needs a team prefix from a provisioning profile. The split is in
  `AppPaths` alone, and the app target's group entitlement is scoped to the iOS SDKs, so the
  macOS build's generated entitlements are exactly what they were. (2) The extension writes
  through the store, never through `TransferQueue`: `upload()` pumps, and starting a transfer is
  the one thing an extension must not do. (3) Copy first, row second. A sweep in the other
  process can then delete a copy no row claims yet — the upload fails visibly with "pick or share
  again" — where the reverse order would leave a row pointing at a half-written file, which is a
  silently truncated upload. (4) No keychain access group: the extension has no use for the key,
  so the C3 keychain code is untouched. It reads the host URL only, to say "no server yet" rather
  than queue into a void. (5) A device build needs a team, and the group has to be in its
  provisioning profile — Xcode registers it when signed in, which is also what C3's keychain note
  asks for. (6) The share extension is not in the macOS build: the embed phase and the target
  dependency carry an `ios` platform filter, which is what keeps `-destination platform=macOS`
  from trying to build an iOS-only target. (7) The C1 note about the server's live-relay/ack race
  is still open and untouched here.

- **2026-07-31 — C5 menu bar extra, Dock drop, iPad layout staged.** DESIGN §4 was reconciled
  first, per the workflow: it now names what a Dock drop actually costs — the Dock delivers a
  drop only for a type the app claims, so the macOS build declares `CFBundleDocumentTypes` for
  `public.data` at `LSHandlerRank = None` plus `LSSupportsOpeningDocumentsInPlace` — and says
  that a login-item launch may restore no window at all, so the queue resumes from the app
  delegate rather than from a screen appearing.
  No `TableCore` changes: this checkpoint is all app target. New `Screens/MenuBarView.swift`
  (the `MenuBarExtra` window: drop zone, "Choose files…", the server list with one-click Take,
  a one-line count of what is moving, and Open table / Settings / Quit), `Platform/MacAppDelegate.swift`
  (`applicationDidFinishLaunching` → `start()`, `application(_:open:)` → the same intake the
  window drop uses, bookmark and all), `Platform/LoginItem.swift` (`SMAppService.mainApp`) with
  an "Open at login" toggle in Settings, and `Screens/Rows.swift`, which is `ServerFileRow`,
  `TransferRow`, `Expiry`, `SectionHeader` and `Banner` lifted out of `MainView` so the window,
  the split layout and the menu bar all draw the same rows. `MainView` splits into `filesSection`
  and `transfersSection` and picks its container: a `NavigationSplitView` at regular width
  (iPad, and iPad only — Slide Over is compact and stacks), the old single list everywhere else.
  `AppModel.start()` is now synchronous, idempotent and owned by the model instead of a view,
  and the list poll is one loop however many views are showing it.
  **72 XCTest tests green** (unchanged from C4 — nothing in `TableCore` moved), three runs clean
  against a dev server with `TABLE_TTL=5s TABLE_TEST_FAULTS=1`.
  **Verified here:** both destinations build; the macOS Release build is installed in
  `/Applications`; the menu bar extra is in the menu bar and its window renders the live list
  with expiry countdowns; `lsregister` shows the app claiming `public.data` as a `None`-rank
  viewer, which is the Dock's precondition; `open -a Table <file>` — the same LaunchServices
  delivery a Dock drop makes — queued and uploaded a file, **including with every window
  closed**, which is C5's "without the main window"; taking that file back from the menu bar ran
  verify → ack → publish and it landed in `~/Downloads`; on the simulator the iPad shows the
  table and the queue side by side while the iPhone still stacks them.
  **Not verified here:** the literal drag gesture onto the Dock icon and onto the menu bar window
  (the delivery underneath both is what was exercised), and the login item itself — registering
  one would put a background item on your machine and prompt you for it, so that toggle is yours
  to try. A build without a signing identity may well be refused; the toggle reports the refusal
  inline and reflects the real registration state back, the same shape as C3's keychain fallback.
  **Reviewer, judgement calls:** (1) `appModel` is a process-wide global, like the background
  session already was. The app delegate has to reach the same model the scenes show, at a moment
  when SwiftUI hands out nothing, and a second `AppModel` would be a second `TransferQueue` on
  one database file. (2) `public.data`, not `public.item`: an upload source is a file, folders
  are refused in `UploadSource`, and not claiming them keeps the Dock from highlighting for
  something that would only fail. (3) `LSSupportsOpeningDocumentsInPlace` had to be turned on
  for macOS — Xcode writes it as `NO` by default and then refuses to build a macOS app that
  declares document types with it off. It is also true: macOS reads the original file where it
  lies rather than copying it in, which is exactly the difference from the iOS intake. (4) The
  menu bar shows the file list and a count, not the whole queue — "glanceable" per DESIGN §4,
  with Open table one click away. (5) The macOS window keeps its single stacked list: §4 asks for
  the side-by-side layout on iPad, and a 520-point window has no room for it. (6) The C1 note
  about the server's live-relay/ack race is still open and untouched here.
