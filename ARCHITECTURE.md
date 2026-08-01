# ARCHITECTURE.md

## Purpose and Authority

This file owns herdr-win's stable technical design: upstream/fork boundaries,
source and patch ownership, Windows runtime and installer topology, durable state,
release architecture, and verification lanes. `PRODUCT.md` owns user-visible
behavior; code and tests remain the detailed implementation truth.

## Source and Ownership Model

- Release source is a fresh checkout of the reviewed `ogulcancelik/herdr` revision
  recorded in `BASE` plus the ordered `patches/delta/series` queue.
  `BASE` records the reviewed upstream commit; the control branch is not an
  integration product branch.
- `BASE` is a deliberate user-selected integration boundary, not a moving pointer.
  Ordinary work and fork-origin synchronization never advance it. Refreshing from
  official upstream is a separate, manual user-directed maintenance operation.
  There is no scheduled upstream replay or release path; manual release dispatch
  always replays the recorded `BASE`.
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
  bounded clipboard/drop image transport, and the narrow Sandbox adapter. That
  adapter invokes the one pre-provisioned standalone guest payload at
  `C:\HerdrSandbox\runtime\herdr.exe`; it never addresses a managed
  `runtime/<build-id>` installation inside the guest. On Windows,
  `herdr status client --json` exposes this exact path as
  `windows_remote_guest_executable` so consumers can reject an absent or different
  adapter contract before provisioning.
- Mailbox 0004 owns deterministic ConPTY packaging, managed Windows distribution,
  fork update sources, installer lifecycle, and the bounded legacy migration.
- Mailbox 0005 owns OpenCode retry/error lifecycle correlation. It must preserve
  actionable terminal failures without surfacing transient errors during an active
  retry.

## Managed Windows Distribution

- The managed install uses one stable launcher and immutable
  `runtime/<build-id>` payloads. Strict Active/Pending records and per-build leases
  prevent old and new runtime components from mixing while sessions remain active.
- The launcher owns runtime selection, process forwarding, lease inheritance, and
  opportunistic activation after the final old lease. It does not terminate user
  sessions or require a service/background poller.
- NSIS owns the setup/uninstall executable shell, embedded inputs, user-visible
  progress/error boundary, and final self-cleanup. The packaged PowerShell helper
  owns filesystem lifecycle, validation, PATH/Installed Apps integration,
  migration, optional user-settings removal, and recoverable install/uninstall
  state. Rust owns runtime selection and downloading/verifying/launching the
  immutable installer asset.
- The packager passes one product display name into NSIS and the helper so setup
  copy, install location, executable metadata, and Installed Apps registration do
  not maintain separate product-name literals. The NSIS presentation uses standard
  MUI2 Welcome/License/Files/Finish pages plus the existing custom uninstall choice.
  Root `LICENSE` is projected once as payload `LICENSE.txt`; that exact file owns
  both the License page and the copy installed beside the product. One high-resolution
  source owns the branded Welcome/Finish artwork; five checked-in BMP3 derivatives
  provide native 100–200% DPI buckets without runtime resampling. Installer
  compression uses datablock optimization, an 8 MiB LZMA dictionary, and solid
  final LZMA settings.
- Interactive and silent uninstall both default to removing
  `%USERPROFILE%\.herdr`; the interactive checkbox or `/KEEP_SETTINGS` can preserve
  it. Settings cleanup stays in the helper's validated filesystem boundary and
  fails closed on ambiguous/reparse-point content rather than following it.
- `src/distribution.rs` is the single fork channel/source configuration. New
  Windows clients consume the separately hashed immutable NSIS asset from the fork
  release; there is no upstream-source fallback. The portable ZIP remains only as
  a user choice and compatibility asset for older immutable clients.
- `website/install.ps1` is a legacy-layout bridge, not the active updater for new
  managed builds. Keep exactly one bounded standalone/junction migration and add no
  speculative migration variants.
- The installer packages the canonical Herdr agent skill to
  `%USERPROFILE%\.agents\skills\herdr`. Install/update replaces that one complete
  directory. Uninstall removes only an exact unchanged installer-owned copy and
  preserves ambiguous or user-modified content.
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
  `.github/workflows/windows-nightly.yml` is legacy-named but owns only manually
  dispatched Windows native tests, immutable asset publication, manifest generation,
  and public-feed verification against recorded `BASE`.
- Manual dispatch requires a herdr-win CalVer `YYYY.MM.DD.N`; the release tag is
  `v<CalVer>`. Portable assets follow
  `herdr-win_v<CalVer>_<os>_<arch>.<ext>` and Windows setup appends `_setup.exe`,
  currently using `windows_amd64`. The manifest's upstream-compatible target keys
  remain separate from filenames so additional upstream-supported platforms can
  use the same release and naming contract later.
- The runtime build ID remains the upstream/control 12-hex pair because it owns
  managed-runtime identity and exact source provenance. CalVer owns the human fork
  release identity; the upstream Cargo version remains compatibility/provenance
  metadata and does not define the herdr-win release.
- `website/preview.json` is generated channel state and the manual release workflow
  is its only writer. Release publication uses the exact tested replay and fails
  closed on source drift, replay conflict, missing/mutable assets, or digest/feed
  mismatch.
- Root `README.md` and `docs/next/README.md` are byte-identical public projections;
  they do not replace `PRODUCT.md` or this architecture owner.

## Verification Architecture

- Control-plane inventory tests validate BASE, series order, mailbox identity, and
  frozen archive invariants before product gates.
- Verification has distinct control-plane inventory, replayed-product, and
  native/package lanes. `CONTRIBUTING.md` owns when each lane runs and keeps broad
  gates on one frozen logical snapshot.
- Formatting, Clippy, and Rust tests run in replayed product source. Windows
  packaging changes add package/vendor checks plus PowerShell 5.1/7 and realistic
  native installer evidence where that boundary changed.
- Broad gates run on an implementation-frozen snapshot. Passing evidence remains
  valid until relevant source, inputs, or environment-sensitive assumptions change.
