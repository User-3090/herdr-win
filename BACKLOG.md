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

- Submit a validated generated WinGet package `hdosys.herdr-win` to
  `microsoft/winget-pkgs` only after an explicit follow-up request. The submission
  must retain its promoted immutable installer URL, digest, and `/WINGET` ownership
  switch; do not rebuild or repoint it during review.
- Measure and reduce warm `herdr --remote` attach latency, especially on Windows
  clients where managed SSH multiplexing is unavailable. Consolidate serial
  platform, binary, and server probes plus avoidable launcher boundaries without
  weakening host verification, authentication, protocol/version checks, or remote
  install safety. Verify warm and cold Windows-to-Windows and Windows-to-Unix
  timings before and after the change.
