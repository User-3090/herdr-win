# herdr-win agent instructions

herdr-win is the Windows-focused control repository for an unofficial Herdr
distribution. Read this file and `CONTRIBUTING.md` before changing anything.

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
  packaging, and immutable prereleases.
- Root `README.md`, `CONTRIBUTING.md`, this file, and repository metadata own
  fork identity. Keep `docs/next/README.md` identical to the root README.

The checked-out product source is useful for history and local inspection, but
nightly release source is always a fresh upstream checkout plus
`patches/delta/series`. A direct source edit is incomplete until its owning
mailbox is regenerated and replayed.

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

- Keep the fork README concise about installation, manual update behavior,
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
- Propose the commit message and get user alignment before committing.
- Push only to the configured fork upstream; never force-push or create tracking
  implicitly.
- Do not open upstream issues or pull requests for the user. Upstream engagement
  must follow `ogulcancelik/herdr`'s current contribution process.
- Never commit secrets, artifacts, logs, temporary replay trees, or checkpoint
  files.
