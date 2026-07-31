# table-client-apple

Native Apple client for [table](../DESIGN.md) — an ephemeral personal file drop.
Swift + SwiftUI, one codebase with iPhone, iPad and macOS destinations (not Catalyst).
Design: `DESIGN.md`; plan of record: `PROGRESS.md`.

## Layout

```
TableCore/                       local Swift package — all logic, no UI
  Sources/TableCore/
    Api/        TableClient — typed wrapper over the HTTP API (URLSession), plus the
                streaming plumbing: a bounded body channel and the task delegates that
                keep a multi-GB transfer O(buffer) in memory
    Crypto/     streaming SHA-256 (CryptoKit)
    Settings/   host URL in UserDefaults, API key in the Keychain
    Transfer/   the conformance-checklist transfer logic (Downloader, Uploader and their
                tasks), the persistent queue (SQLite via GRDB) with its retry policy, and
                the publish step
  Tests/TableCoreTests/          XCTest: the conformance suite plus unit tests
Table/                           app target (iOS + iPadOS + macOS destinations)
  App/        entry point, the container that wires TableCore up, and the observable
              model both screens read
  Screens/    MainView (server list + transfer queue), SettingsView
  Platform/   per-platform glue: where files land, the macOS drop/picker intake, and
              the security-scoped bookmarks that let a queued upload survive a relaunch
```

`TableCore` imports no UI framework, so every transfer path runs under tests off-device.

## Dev loop

The conformance tests run against a real `table-server`. Start one (see
`table-server/CLAUDE.md`), then point the tests at it:

```sh
# dev server: short TTL so the expiry test runs, fault injection for the drop scenarios
TABLE_API_KEY=devkey TABLE_DATA_DIR=$(mktemp -d) TABLE_TTL=5s TABLE_TEST_FAULTS=1 \
  TABLE_ADDR=127.0.0.1:8080 go run .

# the package's tests (unit + conformance)
cd TableCore && TABLE_URL=http://127.0.0.1:8080 TABLE_API_KEY=devkey \
  TABLE_TTL_SECONDS=5 TABLE_TEST_FAULTS=1 swift test
```

Without `TABLE_URL`/`TABLE_API_KEY` the conformance tests skip with a message and the unit
tests still run. `TABLE_TTL_SECONDS` gates the expiry test alone, and `TABLE_TEST_FAULTS=1`
— which the dev server needs too — gates the scenario 10 drop tests.

`swift test` builds for macOS; the iOS destination is compiled by building the app
(below), which needs the iOS platform installed: `xcodebuild -downloadPlatform iOS`.

## Running the app

```sh
xcodebuild -project Table.xcodeproj -scheme Table -destination 'platform=macOS' build
xcodebuild -project Table.xcodeproj -scheme Table -destination 'generic/platform=iOS Simulator' build
open ~/Library/Developer/Xcode/DerivedData/Table-*/Build/Products/Debug/Table.app
```

Against a local dev server, Settings (⌘,) wants `http://127.0.0.1:8080`, the key it was
started with, and **Allow plain http://** on — conformance rule 13 refuses the host otherwise.
The app is sandboxed: its queue and partial downloads live in
`~/Library/Containers/rainbowroachie.Table/Data/Library/Application Support/table`, and
finished downloads are moved to `~/Downloads`.
