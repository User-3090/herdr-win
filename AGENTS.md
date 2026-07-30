# herdr-win repository overlay

The global OpenCode working agreement owns reusable personal workflow. This file
owns only herdr-win repository behavior and constraints; it overrides global
defaults where they differ. Do not copy global workflow or create project
`.opencode/` configuration.

## Canonical owners and precedence

- Code and tests own detailed implementation behavior.
- `PRODUCT.md` owns stable user-visible fork behavior, terminology, supported
  choices, and acceptance outcomes.
- `ARCHITECTURE.md` owns stable technical boundaries, source/replay topology,
  Windows distribution design, state ownership, and verification architecture.
- `CONTRIBUTING.md` owns change classification, mailbox maintenance, replay,
  verification, documentation projection, commit, and upstream-engagement
  procedure.
- `BACKLOG.md` owns open, planned, blocked, or deferred product work.
- `AGENT_IMPROVEMENTS.md` owns evidence-backed herdr-win-specific workflow,
  tooling, test, and skill improvement proposals.
- `.agent/sessions/<session-id>/` owns ignored task-local `TASK.md`, `STATE.md`,
  and `LOG.md` state for long work.

After system and current-user instructions, local precedence is this file,
`PRODUCT.md`, `ARCHITECTURE.md`, `CONTRIBUTING.md`, active session state, then
`BACKLOG.md`. Improvement proposals are not active rules until accepted into an
owning file.

Route each durable decision to exactly one owner above. Cross-project OpenCode
behavior belongs in the global configuration repository. Do not invent another
active memory owner.

## Identity and source invariants

- Official upstream: `ogulcancelik/herdr`.
- This repository: `User-3090/herdr-win`, an unofficial Windows-focused
  distribution fork.
- Release source is replayed upstream source plus the maintained delta, not an
  independently developed product line.
- Runtime identity remains `herdr`: package, executable, command, config, state,
  sockets, and protocol. Fork identity belongs only in repository/release/update
  presentation.
- Keep the delta small, explicit, replayable, and upstreamable.
- `patches/delta/` owns maintained product behavior; `series` owns order and
  `BASE` records the reviewed upstream commit.
- Never autonomously fetch, merge, rebase, replay onto, or otherwise refresh from
  official upstream `ogulcancelik/herdr` during ordinary work. Work against the
  commit already recorded in `BASE`. An upstream refresh is a separate maintenance
  task requiring the user's explicit instruction; the scheduled nightly may test
  current upstream through its own workflow but does not authorize changing the
  control checkout, `BASE`, or the maintained mailboxes. Synchronizing this fork's
  configured `origin` for normal collaboration and delivery remains allowed.
- `patches/upstream/` is a frozen historical archive. Never regenerate, rename, or
  delete it; external links may depend on exact paths.
- `scripts/test_delta_patches.py` and `scripts/test_upstream_patches.py` own queue
  control invariants.
- `.github/workflows/ci.yml` owns cheap PR/manual replay validation.
- `.github/workflows/windows-nightly.yml` owns scheduled/manual Windows testing,
  immutable publication, manifest generation, and feed verification.
- `website/preview.json` is generated channel state; the nightly workflow is its
  only writer.
- `src/distribution.rs` in replayed source owns the fork channel and source URLs.
- Root `README.md` and `docs/next/README.md` are one mirrored public-documentation
  projection of relevant `PRODUCT.md` behavior.

## Repository and session boundaries

- Treat this directory as the root and `master` as the control branch; stop for
  direction on another branch.
- Preserve recovery stashes and unrelated shared-worktree changes.
- Never commit `.agent/`, generated replay/build evidence, logs, binaries,
  credentials, private data, or temporary worktrees.
- Long or resumable work uses exactly one `.agent/sessions/<session-id>/` unless
  `OPENCODE_SESSION_DIR` or `AGENT_SESSION_DIR` selects another owner. Never create
  repository-root `TASK.md`, `STATE.md`, or `LOG.md`, and never write another
  session's directory.

## Product and implementation constraints

- Preserve the user-visible promises in `PRODUCT.md` and technical boundaries in
  `ARCHITECTURE.md`; do not hide a changed product or architecture decision inside
  a mailbox refresh or procedural edit.
- Status inspection is pure and never starts or retries work.
- Keyboard-first terminal interaction remains complete end to end.
- Windows PTY integration owns process-tree cleanup, handle inheritance, resize,
  and byte-stream behavior explicitly. Compile Windows-only code only for Windows.
- Do not add `unsafe` unless unavoidable at a reviewed FFI boundary.
- Avoid production `unwrap`/`expect`; propagate contextual errors.
- Use `tracing` instead of production `eprintln!`/`dbg!`.
- Keep async cancellation-safe and avoid holding non-async locks across `.await`.
- Keep `#[allow(...)]` narrow, local, and justified.
