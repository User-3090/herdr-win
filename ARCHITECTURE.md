# ARCHITECTURE.md

## Purpose and Authority

This file owns herdr-win's stable technical design: upstream/fork boundaries,
source and patch ownership, Windows runtime and installer topology, durable state,
release architecture, and verification lanes. `PRODUCT.md` owns user-visible
behavior; code and tests remain the detailed implementation truth.

## Source and Ownership Model

- Release source is a fresh checkout of the exact commit behind the upstream stable
  release recorded in `BASE` plus the ordered `patches/delta/series` queue. At each
  explicit manual refresh, that commit must be the latest non-draft,
  non-prerelease stable release then published by `ogulcancelik/herdr`; the control
  branch is not an integration product branch.
- `BASE` is a deliberate reviewed stable-release boundary, not a moving pointer.
  Ordinary work and fork-origin synchronization never advance it. Between explicit
  user-directed refreshes, releases stay on the recorded stable source even if
  upstream moves. There is no scheduled upstream replay or release path; manual
  release dispatch always replays the recorded `BASE` and verifies its `v<Cargo
  version>` stable tag.
- Each maintained product responsibility has one logical mailbox. Evolving a
  responsibility refreshes its mailbox rather than appending development history.
  A new mailbox requires an independent owner, verification plan, and upstream
  integration path.
- Repository branding, queue controls, GitHub workflows, release metadata, and
  generated channel state are control-plane concerns and stay outside product
  mailboxes.
- `patches/upstream/` is a frozen historical archive. `patches/delta/` is the only
  active product delta; `series` is the only application order.
- Upstream owns general Herdr behavior. Fork-specific implementation must reuse
  upstream owners where practical and must not create a parallel command, config,
  protocol, state namespace, or general product implementation.

## Maintained Delta Boundaries

- Mailbox 0001 owns Windows terminal appearance, color/cursor transport, rendering,
  and Windows VTI input behavior.
- Mailbox 0003 owns shared remote orchestration, Windows SSH/named-pipe attach,
  and bounded clipboard/drop image transport. For a Windows remote host, its
  encoded PowerShell bridge resolves `herdr.exe` from the SSH user's `PATH` with
  `Get-Command` restricted to `Application`, then invokes that exact result with
  the optional session name and `remote-client-bridge`. This path has no
  Sandbox-specific executable or status contract, compatibility fallback, live
  handoff, or automatic Windows remote installation.
- Mailbox 0004 owns deterministic ConPTY packaging, managed Windows distribution,
  fork update sources, and installer lifecycle.
- Mailbox 0005 owns OpenCode retry/error lifecycle correlation. It must preserve
  actionable terminal failures without surfacing transient errors during an active
  retry.

## Managed Windows Distribution

- The managed install uses exactly one stable launcher at `bin/herdr.exe` and
  immutable `runtime/<build-id>` payloads. The launcher starts the selected payload
  directly; runtime directories contain no dispatcher or second launcher. Strict
  Active/Pending records and per-build leases prevent old and new runtime components
  from mixing while sessions remain active.
- The launcher owns runtime selection, process forwarding, lease inheritance, and
  opportunistic activation after the final old lease. On a normal payload exit, it
  invokes the existing installer helper only when pending launcher publication or
  runtime pruning is needed. It does not terminate user sessions or require a
  service, reparse point, reboot replacement, or background poller.
- Setup serializes launcher changes with `state/launcher.lock`. It replaces an idle
  launcher atomically or writes one hash-addressed `launcher.pending-<sha256>.exe`
  plus a strict pending record while the launcher is in use. The post-exit helper
  waits for its launcher parent, validates the pending hash and private build ID,
  then publishes through the existing transaction/backup boundary without first
  deleting the working launcher. Setup and later safe exits repair a hard-kill
  interruption from the same pending state.
- Active plus optional Pending are the only retained runtime identities. Under the
  existing coordination lock, post-exit/setup maintenance transactionally removes
  every other exact runtime whose lease can be acquired exclusively. Busy,
  malformed, reparse-point, or otherwise ambiguous content is preserved and causes
  the maintenance attempt to report failure rather than broadening deletion.
- NSIS owns the setup/uninstall executable shell, embedded inputs, and user-visible
  progress/error boundary. Uninstall runs the embedded temporary PowerShell helper
  and never mutates the installed root directly; that helper owns final root cleanup
  while holding the persistent lifecycle lock, plus filesystem validation, launcher
  publication, runtime pruning, PATH/Installed Apps integration, optional
  user-settings removal, and recoverable install/uninstall state. Rust owns runtime
  selection and
  downloading/verifying/launching the immutable installer asset.
- The persistent sibling lifecycle lock distinguishes a live operation from a dead
  transaction. Once that exclusive lock is acquired, setup and uninstall validate
  every matching transaction marker, root manifest, remaining managed tree, lease,
  and process path before resuming deletion. A complete current root keeps the
  normal update path; an exact partial root is removed and setup publishes a fresh
  root. Unknown content, reparse points, active leases, and active process images
  remain fail-closed and preserved.
- The packager owns installer-facing product identity inputs. It passes one runtime
  product name into NSIS and the helper, plus one title-cased human distribution
  display name, a derived short UI version, and the fork and official-upstream URLs
  into NSIS. The runtime/install-root identity remains Herdr, while executable
  metadata and Installed Apps consistently present **Herdr Win**. The NSIS presentation
  uses standard MUI2 Welcome/License/Files/Finish pages plus the existing custom
  uninstall choice. Window, Welcome, progress, and Finish presentation reuse that
  one display name; Welcome and Finish titles reuse the same derived base version.
  Welcome identifies the unofficial stable-plus-patches distribution without
  displaying its fixed path. Finish exposes separate user-invoked fork and upstream
  links and never launches Herdr or a browser automatically. Root `LICENSE` is
  projected once as payload `LICENSE.txt`; that exact file owns both the License
  page and the copy installed beside the product. One high-resolution source owns
  the branded Welcome/Finish artwork; five checked-in BMP3 derivatives provide
  native 100–200% DPI buckets without runtime resampling. Installer compression
  uses datablock optimization, an 8 MiB LZMA dictionary, and solid final LZMA settings.
- Install/update canonicalizes the managed `bin` path as the first user-PATH entry,
  removes only duplicate spellings of that same managed path, preserves every
  unrelated entry and its order, and broadcasts a real environment change.
  Uninstall removes only that managed entry, restoring any previously shadowed
  upstream/native command for newly started processes.
- Interactive and silent uninstall both preserve `%USERPROFILE%\.herdr` by
  default; the interactive checkbox or `/REMOVE_SETTINGS` explicitly authorizes
  deletion. Settings cleanup stays in the helper's validated filesystem boundary
  and fails closed on ambiguous/reparse-point content rather than following it.
- `src/distribution.rs` is the single fork channel/source configuration. New
  Windows clients consume the separately hashed immutable NSIS asset from the fork
  release; there is no upstream-source fallback. The portable ZIP remains only as
  a user choice and compatibility asset for older immutable clients.
- The managed setup accepts only a missing install root or the exact current
  managed layout. Any other root is preserved and rejected with an uninstall-first
  action; there are no migration, compatibility, or backup branches. In particular,
  a runtime-local `herdr-launcher.exe` marks the former two-hop layout and is rejected
  before repair, PATH, or ARP mutation. The user removes its existing **Herdr** entry
  before a fresh **Herdr Win** install, so setup never co-owns duplicate package
  registrations.
- `packaging/windows/managed-skill-hashes.txt` is the one append-only ownership
  manifest for the current and every historically installer-delivered
  `skills/herdr/SKILL.md` byte hash. The packager validates that the current payload
  is present; NSIS embeds the payload and the same manifest into setup and uninstall
  without adding either to the persistent managed-root layout. The existing
  PowerShell boundary copies a missing skill, replaces a known hash, and preserves
  an unknown regular file while returning a visible setup warning.
- Skill inspection is pure. Across the universal root and configured/default Claude
  roots, only all-known-or-absent state selects the interactive removal checkbox;
  unknown or ambiguous state leaves it clear. Interactive selection or
  `/REMOVE_SKILL` authorizes exact unknown `SKILL.md` removal, while silent automatic
  cleanup removes only known hashes. A skill directory is removed only after an
  authorized file removal and an empty-directory check. Foreign siblings are never
  recursively deleted, and reparse points or ambiguous collisions remain preserved
  without per-install skill markers, transactions, or locks.
- Future installer work uses the global ordinary-local-application threat model
  unless the user explicitly chooses stronger guarantees. Prefer failing closed
  and preserving benign residue over adding custom recovery/deletion state.

## Windows and Rust Boundaries

- Windows PTY integration owns process-tree cleanup, handle inheritance, resize,
  and byte-stream behavior explicitly; Windows-only code compiles only on Windows.
- Native/FFI code remains narrow, reviewed, and justified by an exact operating
  system boundary. Controlled internal Rust paths stay direct and propagate
  contextual errors without production `unwrap`/`expect`.
- Async work remains cancellation-safe and does not hold non-async locks across
  `.await`. Production diagnostics use `tracing`.

## Release and Generated State

- `.github/workflows/ci.yml` owns cheap replay validation.
  `.github/workflows/release.yml` owns one manually dispatched workflow with two
  explicit operations: build a retained cross-platform candidate, or promote one
  successful candidate run without rebuilding it. No event or schedule invokes
  either operation automatically.
- A build dispatch requires a herdr-win CalVer `YYYY.MM.DD.N`. It runs Windows
  native/package tests and the four upstream-supported Linux/macOS executable
  builds. Every platform job independently replays recorded `BASE` and the queue;
  each source tree must match the tree tested by the Windows owner job, while one
  shared upstream/control build ID and protocol value identify all assets.
- A successful build retains its candidate artifacts for 14 days. The Windows
  candidate owns `RELEASE_CANDIDATE.json`, which records the workflow run and
  attempt, CalVer, source/control identities, protocol, and exact expected release
  filenames. Each candidate asset has a SHA-256 sidecar. Candidate creation does
  not create a tag, release, manifest commit, or other published channel state.
- A promotion dispatch requires only the candidate build run ID. It fails closed
  unless that run completed successfully in this repository and workflow on the
  still-current `master` control commit, its metadata identifies that run and a
  valid attempt, all source identities and filenames are coherent, and the complete
  candidate file set matches every sidecar digest. Promotion downloads those
  retained artifacts and publishes the exact bytes; it contains no source replay,
  compile, or package path. Only the promotion job receives Actions read and
  repository write permissions.
- The promoted release tag is `v<CalVer>`. Linux and macOS publish raw executables named
  `herdr-win_v<CalVer>_{linux,macos}_{amd64,arm64}` for direct remote installation.
  Windows keeps `herdr-win_v<CalVer>_windows_amd64.zip` and the corresponding
  `_setup.exe`. The manifest's upstream-compatible target keys remain separate from
  these fork-presented filenames.
- Publication and the generated manifest proceed only when all six target assets
  have verified SHA-256 digests; retained historical manifest entries may remain
  Windows-only.
- Machine-consumed tags and asset filenames remain CalVer-only for existing updater
  compatibility. The GitHub release title is `herdr-win v<CalVer> (Herdr
  v<upstream-version>)`; release notes and installer metadata expose that same
  stable upstream version alongside the CalVer-bearing original filename.
- The runtime build ID remains the upstream/control 12-hex pair because it owns
  managed-runtime identity and exact source provenance. CalVer owns the human fork
  release identity; the upstream Cargo version remains compatibility/provenance
  metadata and does not define the herdr-win release.
- `website/preview.json` is generated channel state and the promotion operation is
  its only writer. Release publication uses the exact tested candidate and fails
  closed on source drift, stale control state, missing/mutable assets, or
  digest/feed mismatch.
- Root `README.md` and `docs/next/README.md` are byte-identical public projections;
  they do not replace `PRODUCT.md` or this architecture owner.

## Verification Architecture

- Control-plane inventory tests validate BASE, series order, mailbox identity, and
  frozen archive invariants before product gates.
- Verification has distinct control-plane inventory, replayed-product, and
  native/package lanes. `CONTRIBUTING.md` owns when each lane runs and keeps broad
  gates on one frozen logical snapshot.
- Formatting, Clippy, and Rust tests run in replayed product source. Cross-platform
  release builds add native target/machine checks and static-link validation for
  Linux. Windows packaging changes add package/vendor checks plus PowerShell 5.1/7
  and realistic native installer evidence where that boundary changed.
- Broad gates run on an implementation-frozen snapshot. Passing evidence remains
  valid until relevant source, inputs, or environment-sensitive assumptions change.
