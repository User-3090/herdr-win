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

- Add tested artifacts for the remaining upstream-supported operating-system and
  architecture targets. Publish them under the same manually approved CalVer and
  `herdr-win_v<CalVer>_<os>_<arch>.<ext>` naming contract as Windows, reserving the
  `_setup.exe` suffix for setup executables; verify each native package boundary
  and one coherent cross-platform manifest before advertising support.
