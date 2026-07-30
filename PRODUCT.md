# PRODUCT.md

## Purpose

This file is the short durable user-perspective truth for herdr-win: the fork's
product promise, visible Windows-specific behavior, terminology, supported choices,
and acceptance outcomes. Upstream Herdr owns general product behavior; code and
tests remain the detailed implementation truth.

## Product Shape and Identity

- herdr-win is an unofficial, upstream-first Windows distribution of Herdr, not a
  separate product line.
- Fork identity appears in repository, release, and update-channel presentation.
  The package, executable, command, configuration, state, sessions, sockets, and
  protocol remain `herdr` and stay compatible with upstream.
- Nightlies currently target Windows x86_64. General CLI, TUI, configuration,
  integration, and issue behavior remains documented and owned upstream unless a
  maintained Windows delta explicitly changes it.
- The maintained user-visible Windows delta covers terminal fidelity, remote
  attach/image transport, managed Windows distribution, and truthful OpenCode
  retry/error lifecycle reporting.

## Installation, Update, and Uninstall

- The normal managed installation is per-user under
  `%LOCALAPPDATA%\Programs\Herdr`, exposes the stable `herdr` command on user
  `PATH`, and registers Herdr in Windows Installed Apps. A portable ZIP remains a
  supported manual alternative.
- The managed installer installs the cross-agent Herdr skill at
  `%USERPROFILE%\.agents\skills\herdr\SKILL.md` and replaces the complete prior
  `herdr` skill directory on install/update.
- Preview updates use only the fork-owned immutable installer asset and verified
  digest. Existing managed sessions continue on their current runtime; a newer
  runtime may remain staged until old sessions exit, after which future launches
  switch atomically. Update never terminates active Herdr sessions.
- Uninstall requires managed sessions to be closed and never terminates them. It
  removes the managed program, user `PATH` entry, Installed Apps registration, and
  an unchanged installer-owned skill while preserving modified skill content and
  user configuration/session data under `%USERPROFILE%\.herdr`.
- The executable and installer are currently unsigned. Documentation must keep the
  SmartScreen warning and digest-verification path clear until signing becomes an
  explicit release capability.

## Interaction and Status

- Keyboard-first terminal operation remains complete end to end.
- User-visible state distinguishes waiting, active, mixed, complete, failed,
  cancelled, stopped, and no-op outcomes whenever they require different user
  understanding or action.
- Status inspection is observational: viewing status never starts, retries, or
  changes work.

## Release Promise

- Published preview assets derive from one tested replay of the selected upstream
  source plus the maintained queue. The portable ZIP, managed installer, and
  manifest digest identify the same source.
- A manually requested release uses the last reviewed upstream commit recorded in
  `BASE`. The scheduled Nightly alone tests current upstream and publishes only if
  the maintained queue still replays and every release gate passes.
- Ordinary pushes do not publish binaries. A replay, build, package, immutability,
  digest, or feed-verification failure prevents or visibly fails the corresponding
  release stage rather than silently publishing a different build.
