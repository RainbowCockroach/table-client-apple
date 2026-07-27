# Progress — table-client-apple

Plan of record for implementation sessions. Working rules are in `CLAUDE.md`:
one checkpoint at a time → tests green → update this file → `git add -A` →
**stop for review. Never commit, never push.**

Prerequisite: a working `table-server` (local dev build is enough).

| # | Checkpoint | Proves | Status |
|---|---|---|---|
| C1 | `TableCore` package: API client + hashing + queue, XCTest conformance-scenario tests against a local server (incl. fault-path tests via `X-Test-Drop-After`) | conformance + fault tests green | not started |
| C2 | macOS destination: main window, settings, drag-and-drop, foreground transfers end-to-end | manual: drop → upload → download on another device | not started |
| C3 | iOS destination: same screens, background `URLSession` transfers, notifications | manual background-transfer pass (DESIGN.md §7) | not started |
| C4 | Share extension + app group plumbing | manual: share from Photos/Files → queued → uploaded | not started |
| C5 | Menu bar extra, Dock drop, iPad layout polish | manual release pass | not started |

Distribution is manual (Xcode / TestFlight) — no release CI planned for this repo.

Status values: `not started` → `in progress` → `staged for review` → `done` (user committed).

## Log

*(append one dated line per session)*
