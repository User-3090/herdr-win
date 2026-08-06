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
  non-prerelease stable release then published by `herdrdev/herdr`; the control
  branch is not an integration product branch.
- Active control-plane checkouts, contributor and contact links, and fork-owned
  installer presentation use the current official repository, `herdrdev/herdr`.
  Imported source at recorded `BASE`, historical changelogs and version snapshots,
  vendor provenance, and the frozen patch archive preserve references from their
  recorded source boundary instead of creating a temporary fork delta.
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
- Mailbox 0006 owns the shared runtime `curl` transfer policy. Runtime fetches ignore
  user `curl` configuration, pass URLs as option values, require TLS 1.2 or newer
  HTTPS for initial requests and redirects, disable URL globbing, and allow at most
  five redirects; callers retain any narrower timeout, size, and digest checks.

## Managed Windows Distribution

- The managed install uses exactly one stable launcher at `bin/herdr.exe` and
  immutable `runtime/<build-id>` payloads. The launcher starts the selected payload
  directly; runtime directories contain no dispatcher or second launcher. Strict
  Active/Pending records and per-build leases prevent old and new runtime components
  from mixing while sessions remain active.
- The launcher owns runtime selection, process forwarding, lease inheritance, and
  opportunistic activation after the final old lease. On a normal payload exit, it
  invokes the installed native helper at `state/installer-helper.exe` only when
  pending launcher publication or runtime pruning is needed. It does not terminate
  user sessions or require a service, reparse point, reboot replacement, or
  background poller.
- Setup serializes launcher changes with `state/launcher.lock`. It replaces an idle
  launcher atomically or writes one hash-addressed `launcher.pending-<sha256>.exe`
  plus a strict pending record while the launcher is in use. The post-exit helper
  waits for its launcher parent, validates the pending hash and private build ID,
  then publishes through the existing staging/backup boundary without first
  deleting the working launcher. Setup and later safe exits repair a hard-kill
  interruption from the same pending state.
- Active plus optional Pending are the only retained runtime identities. Under the
  existing coordination lock, post-exit/setup maintenance removes
  every other exact runtime whose lease can be acquired exclusively. Busy,
  malformed, reparse-point, or otherwise ambiguous content is preserved and causes
  the maintenance attempt to report failure rather than broadening deletion.
- The Windows package has three Rust executables: the user-facing runtime, the stable
  launcher, and the internal installer helper. NSIS owns the setup/uninstall shell,
  embedded inputs, and user-visible progress/error boundary. It runs the embedded
  temporary native helper and never mutates the installed root directly. The helper
  owns final root cleanup while holding the persistent lifecycle lock, filesystem
  validation, launcher publication, runtime pruning, PATH/Installed Apps integration,
  optional user-settings removal, and recoverable install/uninstall state. Rust also
  owns runtime selection and downloading/verifying/launching the immutable installer
  asset.
- NSIS forces its embedded CRC check and recognizes package-manager and destructive
  custom flags only as exact tokens.
- The helper validates the complete managed Installed Apps value set, registry
  kinds, and content before mutation or key removal; unknown values or subkeys are
  preserved and rejected. Setup, uninstall, and registration removal accept only
  the current native-helper quiet-uninstall command. There is no prior command,
  script helper, or bridge acceptance path.
- Installed Apps quiet uninstall invokes `state/installer-helper.exe` directly.
  That process creates one random strict sibling rendezvous, starts the NSIS
  uninstaller in a bounded native job, and waits for the embedded helper's terminal
  result. The embedded helper accepts only that exact installed-helper process,
  moves its locked image to the validated sibling handoff path, removes the managed
  root and registration, publishes the result, then deletes the handoff after the
  waiting process exits. A nonterminal cleanup fault restores the helper and exact
  retry markers before reporting failure. Fresh installs, updates, quiet uninstall,
  and post-exit maintenance therefore ship and invoke no PowerShell payload.
- NSIS accepts `/WINGET` as the sole explicit package-manager origin signal and
  passes a bounded Direct/WinGet value into the helper. The helper owns the optional
  strict UTF-8 `state/package-manager` record; only the exact
  `herdr-package-manager-v1\nmanager=winget\n` bytes establish WinGet ownership.
  Fresh WinGet setup publishes it with the managed tree, repeated WinGet or direct
  setup preserves it, and uninstall removes it. Rust derives ownership only through
  the validated current managed-install root; malformed or unreadable records fail
  closed rather than being inferred from PATH, ARP, process ancestry, or WinGet
  metadata.
- The existing startup update thread remains feed-driven for direct installs. For
  an exact WinGet-owned root, it takes the target CalVer from the validated preview
  feed and runs one bounded, non-interactive `winget show` query for that exact
  package, official source, version, x64 architecture, and user scope. The query is
  contained in a kill-on-close Windows job. Only success publishes release notes and
  an update event; package/version absence is pending, while launch, source, timeout,
  containment, and other failures suppress the action and are logged. No polling,
  second availability feed, or package-manager state is added.
- The persistent sibling lifecycle lock serializes every installer generation.
  Fresh and update work uses uniquely named same-parent staging only; once the lock
  is acquired, any stale regular staging tree is disposable and its grammar never
  decides whether the user's requested operation may continue. Cleanup failure
  preserves that private staging with a warning. Uninstall has no sibling
  transaction, cleanup manifest, or rollback parser: under the launcher gate it
  validates active processes and leases, publishes `state/uninstall.pending`, and
  removes `bin` plus immutable runtimes directly. The remaining exact residual owns
  idempotent metadata and self-cleanup.
- Payload launch independently acquires `state/launcher.lock`, validates the stable
  launcher, and rejects any present `state/uninstall.pending` marker before runtime
  selection or `CreateProcess`. Thus a killed uninstaller cannot admit a new session
  between releasing its process-owned lock and a later recovery pass; the existing
  launcher is reused and no service or second launch path is added.
- The packager owns installer-facing product identity inputs and validates the
  runtime, launcher, and native helper as three distinct x64 executables. It passes
  one runtime product name, one title-cased human distribution display name, a
  derived short UI version, and the fork and official-upstream URLs into NSIS. The
  runtime/install-root identity remains Herdr, while executable
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
- Install/update preserves the raw user-PATH registry kind and bytes. It adds the
  literal managed `bin` path first only when no effective equivalent exists, records
  that exact ownership in ARP, and never claims or rewrites an equivalent user-owned
  spelling. Uninstall removes at most one exact literal entry only when ARP proves
  this installer added it, preserving every other entry and its order.
- Interactive and silent uninstall both preserve `%USERPROFILE%\.herdr` by
  default; the interactive checkbox or `/REMOVE_SETTINGS` explicitly authorizes
  deletion. Settings cleanup stays in the helper's validated filesystem boundary
  and never follows ambiguous/reparse-point content. It runs after managed skill,
  application, PATH, and Installed Apps cleanup; an unsafe or locked settings
  residual is preserved and reported without changing successful application
  removal into failure. The managed install/runtime tree is not best-effort state:
  its active process and lease checks remain required uninstall gates.
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
- Exact ARP ownership plus the current bin sentinel and install manifest permit
  repair of the installer control filenames only: missing helper or uninstaller
  files are recreated, and changed regular files are atomically
  replaced through the native `ReplaceFileW` boundary with backups of their actual
  current bytes. When this
  normal path cannot classify a root already bound by exact current registration,
  the same helper treats the dedicated managed root as a complete convergence root:
  it holds available launcher coordination, rejects active processes, leases, and
  reparse points, removes the old root, and either publishes the requested current
  build or completes removal. This is current-format convergence, not legacy
  adoption or a published-hash bypass.
- `packaging/windows/managed-skill-hashes.txt` is the one append-only ownership
  manifest for the current and every historically installer-delivered
  `skills/herdr/SKILL.md` byte hash. The packager validates that the current payload
  is present; NSIS embeds the payload and the same manifest into setup and uninstall
  without adding either to the persistent managed-root layout. The native helper
  copies a missing skill, replaces a known hash, and preserves an unknown regular
  file while returning a visible setup warning.
- Skill inspection is pure. Across the universal root and configured/default Claude
  roots, only all-known-or-absent state selects the interactive removal checkbox;
  unknown or ambiguous state leaves it clear. Interactive selection or
  `/REMOVE_SKILL` authorizes exact unknown `SKILL.md` removal, while silent automatic
  cleanup removes only known hashes. A skill directory is removed only after an
  authorized file removal and an empty-directory check. Foreign siblings are never
  recursively deleted, and reparse points or ambiguous collisions remain preserved
  without per-install skill markers, transactions, or locks.
- Future installer work uses the global ordinary-local-application threat model
  unless the user explicitly chooses stronger guarantees. Measure success by the
  requested installed/current or absent terminal state. Private staging and
  malformed recovery metadata are never product-level blockers; preserve only true
  unsafe boundaries such as reparse escapes, active installed processes, and live
  runtime leases.

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
  shared candidate-scoped build ID and protocol value identify all assets. The
  build ID combines the upstream prefix with a hash of the selected control commit,
  workflow run ID, and attempt, preventing byte-distinct rebuilds of unchanged
  source from colliding in one immutable runtime directory.
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
- Promotion publishes those six target artifacts without candidate checksum
  sidecars. Candidate sidecars remain internal verification inputs; GitHub records
  SHA-256 for every immutable release asset and the update manifest carries the same
  six verified digests.
- A WinGet community submission is generated only after immutable promotion and
  remains external release output under ignored `target/`, not a second checked-in
  package tree. Its multi-file manifest uses package ID `hdosys.herdr-win`, the
  CalVer as `PackageVersion`, x64 per-user NSIS metadata, the exact immutable setup
  URL and GitHub-recorded SHA-256, and silent switches `/S /WINGET`. Neither the
  release workflow nor ordinary repository delivery submits the external PR.
- Publication and the generated manifest proceed only when all six target assets
  have verified SHA-256 digests; retained historical manifest entries may remain
  Windows-only.
- Machine-consumed tags and asset filenames remain CalVer-only for existing updater
  compatibility. The GitHub release title is `herdr-win v<CalVer> (Herdr
  v<upstream-version>)`; release notes and installer metadata expose that same
  stable upstream version alongside the CalVer-bearing original filename.
- The runtime build ID remains two lowercase 12-hex components because it owns
  managed-runtime identity: the upstream prefix plus the candidate identity hash.
  Full upstream/control hashes and run/attempt metadata remain the exact provenance
  owners. CalVer owns the human fork release identity; the upstream Cargo version
  remains compatibility/provenance metadata and does not define the herdr-win release.
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
  Linux. Windows packaging changes add package/vendor checks, native quiet-uninstall,
  helper and launcher tests, and realistic installer evidence where that boundary
  changed.
- Broad gates run on an implementation-frozen snapshot. Passing evidence remains
  valid until relevant source, inputs, or environment-sensitive assumptions change.
