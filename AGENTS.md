# herdr-win agent instructions

herdr-win is the Windows-focused control repository for an unofficial Herdr
distribution. Read this file and `CONTRIBUTING.md` before changing anything.

The reusable personal workflow in `~/.config/opencode/AGENTS.md` applies here.
This file is the project overlay and takes precedence for Herdr-specific identity,
ownership, patch, release, verification, and delivery rules. Do not copy the
global workflow or create project-local `.opencode/` configuration; improve a
missing generic capability in the global owner instead.

## Identity invariants

- Repository and nightly channel: `herdr-win`.
- Cargo package, executable, command, configuration, state, sessions, sockets,
  API, and wire protocol: `herdr`.
- Never introduce a second runtime identity or migrate user state for branding.
- Treat `ogulcancelik/herdr` as upstream. Do not imply that fork releases are
  official upstream releases.

## Sources of truth

- `patches/delta/` is the canonical maintained product delta and application
  order. Refresh an evolving feature's existing mailbox in place.
- `patches/upstream/` is a frozen compatibility archive. Preserve every existing
  mailbox filename and URL; current work does not belong there.
- `.github/workflows/ci.yml` owns cheap PR/manual replay validation.
- `.github/workflows/windows-nightly.yml` owns scheduled/manual Windows testing,
  packaging, immutable prereleases, and publication of the fork preview update
  manifest.
- `website/preview.json` is generated update-channel state. The nightly workflow
  updates it only after publishing a verified release; do not hand-edit it.
- Replayed `src/distribution.rs`, owned by delta patch 0004, is the only owner of
  fork update channel and source URLs. Local and nightly builds must use it
  without URL/channel environment variables or upstream fallbacks. Keep the
  Windows installer URL pinned to a reviewed immutable control commit.
- Repository release immutability and the
  `HERDR_RELEASE_IMMUTABILITY_ENABLED=true` repository-variable attestation must
  remain enabled. Nightly checks the attestation before packaging and the actual
  release's immutable flag before advancing the manifest.
- Root `README.md`, `CONTRIBUTING.md`, this file, and repository metadata own
  fork identity. Keep `docs/next/README.md` identical to the root README.

The checked-out product source is useful for history and local inspection, but
nightly release source is always a fresh upstream checkout plus
`patches/delta/series`. A direct source edit is incomplete until its owning
mailbox is regenerated and replayed.

Route durable decisions to one existing owner: agent/repository workflow to this
file, contribution and replay procedure to `CONTRIBUTING.md`, public fork identity
and user-facing install/update behavior to both README copies, maintained product
behavior or carried documentation to its logical delta mailbox, and release
behavior to the owning workflow/tests. Do not invent permanent memory or backlog
files without explicit approval. Long-task checkpoints remain external through
the global `portable-checkpoint` workflow and must never be committed.

## Precedence and repository safety

1. Platform/system safety and the current user instruction.
2. This project overlay and its identity/release invariants.
3. `CONTRIBUTING.md` and the project owners named above.
4. The global OpenCode working agreement.

- Treat this directory as the repository root and `master` as the control branch.
  Stop for direction if an existing checkout is unexpectedly on another branch.
- Preserve unrelated user/shared-worktree changes and recovery stashes. Never
  reformat, stage, or commit work outside the current slice.
- Before reset, restore, checkout over files, clean, rebase, deletion, overwrite,
  history rewrite, or force-push, stop and request explicit approval with the
  exact command, affected paths, status/diff scope, safer alternatives, recovery
  plan, and risks.
- `direct-builder` owns the smallest verified vertical slice. For maintained
  product behavior, the canonical implementation owner is the logical delta
  mailbox, not the checked-out source alone.

## Working model

Classify work before editing:

1. **Control-plane change:** edit branding, workflow, or inventory owners
   directly and keep it out of product patches.
2. **Maintained product change:** start from current upstream `master`, replay
   the full queue, change the existing logical owner, regenerate its stable
   mailbox, then replay the checked-in queue from scratch.
3. **Upstream behavior:** prefer an upstream fix and remove or shrink the fork
   patch after it lands. Follow upstream's contribution rules separately.

Nightly must remain ephemeral. Do not create or force-push an integration branch,
merge upstream into a release branch, resolve conflicts automatically, or build
releases on ordinary pushes. A replay conflict is a maintenance signal and must
fail closed.

Manifest publication must execute the generator carried from the tested replay,
not code from a mutable default-branch checkout. It may commit only
`website/preview.json` and must fail instead of rebasing if release inputs or the
selected control revision change during a run.

On a same-source rerun, the existing immutable release is canonical because a
fresh Windows link is not guaranteed to be bit-for-bit identical. Validate and
download the release assets, derive the manifest digest from that immutable ZIP,
and never replace or repoint the published release.

## Product design guardrails

- Keep state separate from runtime and rendering pure.
- Keep Windows implementation under `src/platform/` or behind compile-gated
  boundaries. Do not make core behavior depend on Windows-only APIs.
- Shared runtime/session facts belong in the server/API path; TUI presentation
  state belongs in the client layer.
- Reuse existing protocol and clipboard/image contracts before adding messages,
  DTOs, services, or compatibility paths.
- Do not add dependencies when existing owners cover the need.
- Rust production code must not use `unwrap()`. Use `tracing` for diagnostics and
  explain every `#[allow]`.

## Patch maintenance

- Keep the queue small and responsibility-oriented rather than mirroring
  development commit history.
- Generate mailboxes with `git format-patch --full-index --binary`.
- Keep stable filenames and `series` order.
- Update `BASE` only after the complete queue is reviewed on that upstream
  commit.
- Keep branding, `.github/`, root README files, and patch-control metadata out of
  product mailboxes.
- Never hand-edit a diff merely to force application; regenerate it from the
  reviewed logical commit.

## Verification

Use the smallest ladder that covers the change, but always include:

```powershell
python -m unittest scripts.test_delta_patches scripts.test_upstream_patches
```

For product patches, verify a clean `git am --3way` replay on current upstream,
then run formatting and relevant Rust tests in the replayed tree. Windows package
changes also require:

```powershell
python -m unittest scripts.test_package_windows_conpty scripts.test_vendor_libghostty_vt scripts.test_vendor_portable_pty
cargo fmt --check
cargo clippy --bin herdr --locked --target x86_64-pc-windows-msvc -- -D warnings
```

Workflow changes require `actionlint` and review of triggers, permissions,
credential persistence, immutable source identity, artifact digests, and release
failure behavior. Native package or installer work requires the GitHub Windows
nightly gates or equivalent real Windows evidence.

## Documentation

- Keep the fork README concise about initial installation, automatic updates,
  upstream attribution, and the runtime-name invariant.
- Keep `README.md` and `docs/next/README.md` byte-for-byte identical.
- General Herdr documentation remains upstream-owned. Fork product documentation
  carried in the nightly source belongs in the logical patch that implements it.
- Do not edit generated preview or version documentation directories.

## Git and GitHub

- Preserve unrelated working-tree changes and recovery stashes.
- Before committing, inspect status, the complete intended diff, and recent log;
  stage only task-owned files.
- Use lowercase conventional commits, no emoji, and no AI co-author lines.
- Commit coherent verified milestones without interrupting for routine wording
  approval, then push immediately to the configured fork upstream. Never
  force-push or create tracking implicitly.
- Do not open upstream issues or pull requests for the user. Upstream engagement
  must follow `ogulcancelik/herdr`'s current contribution process.
- Never commit secrets, artifacts, logs, temporary replay trees, or checkpoint
  files.
- Final responses include changed files/docs, verification, net complexity,
  artifact/installer path when applicable, commit/push result, unresolved risks,
  next action, and checkpoint path when used.
