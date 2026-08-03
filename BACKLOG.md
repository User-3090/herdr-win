# BACKLOG.md

Open, planned, blocked, or deferred herdr-win product work only. User-visible
product rules belong in `PRODUCT.md`; stable technical design belongs in
`ARCHITECTURE.md`; workflow/tooling/test/skill proposals belong in
`AGENT_IMPROVEMENTS.md`.

## Rules

- Keep items actionable and current.
- Remove completed or obsolete items instead of preserving history.
- Include expected verification when known.
- Do not use this file for task logs, accepted product rules, architecture, or
  agent process notes.

## Items

- Dispatch the first cross-platform candidate build, verify every native package
  boundary and the coherent six-target candidate, then promote that exact workflow
  run and verify its manifest. Only after that real-build evidence exists, project
  Linux/macOS availability into `PRODUCT.md` and the mirrored public README.
- Prepare, validate, and submit the WinGet package `hdosys.herdr-win` only after an
  explicit follow-up request. Decide updater delegation to WinGet at that time;
  this launcher-lifecycle milestone keeps the existing fork-owned updater.
