# PRODUCT.md

## Purpose

This file is the short durable user-perspective truth for herdr-win: the fork's
product promise, visible Windows-specific behavior, terminology, supported choices,
and acceptance outcomes. Upstream Herdr owns general product behavior; code and
tests remain the detailed implementation truth.

## Product Shape and Identity

- herdr-win is an unofficial, upstream-first Windows distribution of Herdr, not a
  separate product line. It exists to advance Herdr's Windows support through a
  small patch set designed to remain reviewable and suitable for upstream.
- Fork identity appears in repository, release, and update-channel presentation.
  The package, executable, command, configuration, state, sessions, sockets, and
  protocol remain `herdr` and stay compatible with upstream.
- herdr-win snapshots currently target Windows x86_64. General CLI, TUI,
  configuration, integration, and issue behavior remains documented and owned
  upstream unless a maintained Windows delta explicitly changes it.
- The maintained user-visible Windows delta covers terminal fidelity, remote
  attach/image transport, managed Windows distribution, and truthful OpenCode
  retry/error lifecycle reporting.

## Installation, Update, and Uninstall

- The normal managed installation is per-user under
  `%LOCALAPPDATA%\Programs\Herdr`, exposes the stable `herdr` command on user
  `PATH`, and registers Herdr in Windows Installed Apps without requiring
  administrator privileges. The installer interface is English-only. Its branded,
  keyboard-operable Windows setup uses the human-facing display name **Herdr Win**
  consistently while the repository and release slug remains `herdr-win`. Welcome
  and Finish include the current reviewed Herdr base version. Setup identifies the
  fork as an unofficial distribution built from the latest reviewed stable Herdr
  release plus the maintained Windows
  patches. The destination remains fixed without displaying a path or offering a
  directory choice on Welcome. Setup presents the Apache-2.0 license before modifying
  files and ends with the exact first command plus separate user-invoked links to the
  fork guide and official upstream project. It never opens Herdr or a browser
  automatically. The installed payload and portable ZIP include the same license as
  `LICENSE.txt`. A portable ZIP remains a supported manual alternative.
- The managed installer copies upstream's canonical Herdr skill to
  `%USERPROFILE%\.agents\skills\herdr\SKILL.md`. When Claude Code is detected,
  it also copies the skill below `CLAUDE_CONFIG_DIR` or
  `%USERPROFILE%\.claude`. Install/update overwrites only `SKILL.md` and
  preserves every sibling file and directory.
- Setup updates only an exact current managed installation. Any other existing
  install layout is preserved and rejected with instructions to uninstall Herdr
  from Windows Installed Apps before running setup again; setup never migrates,
  backs up, or removes an incompatible layout.
- Snapshot updates use only the fork-owned immutable setup asset and verified
  digest through the fork-owned update feed. Existing managed sessions continue on
  their current runtime; a newer runtime may remain staged until old sessions exit,
  after which future launches switch atomically. Update never terminates active
  Herdr sessions.
- Uninstall requires managed sessions to be closed and never terminates them. It
  removes the managed program, user `PATH` entry, Installed Apps registration, and
  `SKILL.md` at its managed universal and Claude locations even when that file was
  edited after installation. Other skill-directory content is preserved, and an
  empty `herdr` skill directory is removed. The interactive uninstaller preserves
  configuration and session data under `%USERPROFILE%\.herdr` by default; users
  must explicitly select the removal checkbox to delete it. Silent uninstall uses
  the same preserve-by-default policy and accepts `/REMOVE_SETTINGS` as the explicit
  deletion choice.
- The executable and setup are currently unsigned. Documentation must keep the
  SmartScreen warning and digest-verification path clear until signing becomes an
  explicit release capability.

## Interaction and Status

- Keyboard-first terminal operation remains complete end to end.
- A native Windows client attaches to a Windows SSH host only through
  `herdr.exe` resolved from that SSH user's `PATH`. It launches that resolved
  application without a fork- or Sandbox-specific path fallback and never
  installs Herdr on the Windows host automatically.
- User-visible state distinguishes waiting, active, mixed, complete, failed,
  cancelled, stopped, and no-op outcomes whenever they require different user
  understanding or action.
- Status inspection is observational: viewing status never starts, retries, or
  changes work.

## Release Promise

- Published snapshot assets are the exact retained outputs of one successful manual
  candidate build of the selected upstream source plus the maintained queue.
  Promotion never rebuilds or repackages them. The portable ZIP, managed installer,
  and manifest digest identify the same source.
- Each release has a manually selected herdr-win CalVer `YYYY.MM.DD.N` and is based
  on the exact latest upstream stable release selected during the most recent
  explicit refresh. Updater-facing tags and assets retain
  `herdr-win_v<CalVer>_<os>_<arch>.<ext>` and `_setup.exe`; the GitHub release title,
  notes, and installer metadata visibly pair that CalVer with `Herdr
  v<upstream-version>`. Source/control hashes remain exact provenance.
- Candidate builds and release promotion are separate manual operations. A build
  requires the intended CalVer, uses the reviewed stable commit recorded in `BASE`,
  and retains its candidate artifacts for 14 days without publishing a release.
  Promotion requires that successful build's workflow run ID and publishes only its
  validated artifacts. An explicit manual refresh separately selects the latest
  non-draft, non-prerelease upstream release and replays the complete queue; no
  scheduled workflow queries, rebases, builds, or publishes current upstream.
- Ordinary pushes do not publish binaries. A replay, build, package, immutability,
  digest, or feed-verification failure prevents or visibly fails the corresponding
  release stage rather than silently publishing a different build.
