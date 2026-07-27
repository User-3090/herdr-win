# herdr-win repository overlay

The global OpenCode working agreement owns reusable personal workflow. This file
owns only herdr-win identity, source, product, and release constraints; it
overrides global defaults where they differ. Read `CONTRIBUTING.md` for the
canonical patch/replay/verification/contribution procedure. Do not copy global
workflow or create project `.opencode/` configuration.

## Identity invariants

- Official upstream: `ogulcancelik/herdr`.
- This repository: `User-3090/herdr-win`, an unofficial Windows-focused
  distribution fork.
- Release source is replayed upstream source plus the maintained delta, not an
  independently developed product line.
- Runtime identity remains `herdr`: package, executable, command, config, state,
  sockets, and protocol. Fork identity belongs only in repository/release/update
  presentation.
- Keep the delta small, explicit, replayable, and upstreamable.

## Canonical owners

- `patches/delta/` owns maintained product behavior; `series` owns order and
  `BASE` records the reviewed upstream commit.
- `patches/upstream/` is a frozen historical archive. Never regenerate, rename, or
  delete it; external links may depend on exact paths.
- `CONTRIBUTING.md` owns change classification, mailbox maintenance, replay,
  verification, documentation, commit, and upstream-engagement procedure.
- `scripts/test_delta_patches.py` and `scripts/test_upstream_patches.py` own queue
  control invariants.
- `.github/workflows/ci.yml` owns cheap PR/manual replay validation.
- `.github/workflows/windows-nightly.yml` owns scheduled/manual Windows testing,
  immutable publication, manifest generation, and feed verification.
- `website/preview.json` is generated channel state; the nightly workflow is its
  only writer.
- `src/distribution.rs` in replayed source owns the fork channel and source URLs.
- Root `README.md` and `docs/next/README.md` are one mirrored public-documentation
  surface.

Route durable decisions to one owner: repository-agent constraints here;
contribution/replay procedure in `CONTRIBUTING.md`; public identity and user-facing
install/update behavior in both README copies; maintained product behavior/docs in
its logical mailbox; executable release behavior in its workflow/tests. Do not
invent permanent memory/backlog files. Checkpoints remain external and uncommitted.

## Repository boundaries

- Treat this directory as the root and `master` as the control branch; stop for
  direction on another branch.
- Preserve recovery stashes and unrelated shared-worktree changes.

## Product design and Rust constraints

- User-visible state must distinguish waiting, active, mixed, complete, failed,
  cancelled, stopped, and no-op outcomes when materially different.
- Status inspection is pure and never starts or retries work.
- Keyboard-first terminal interaction remains complete end to end.
- Windows PTY integration owns process-tree cleanup, handle inheritance, resize,
  and byte-stream behavior explicitly. Compile Windows-only code only for Windows.
- Do not add `unsafe` unless unavoidable at a reviewed FFI boundary.
- Avoid production `unwrap`/`expect`; propagate contextual errors.
- Use `tracing` instead of production `eprintln!`/`dbg!`.
- Keep async cancellation-safe and avoid holding non-async locks across `.await`.
- Keep `#[allow(...)]` narrow, local, and justified.
