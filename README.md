# herdr-win

**An unofficial, upstream-first Windows distribution of [Herdr](https://github.com/ogulcancelik/herdr).**

[![Patch replay](https://github.com/User-3090/herdr-win/actions/workflows/ci.yml/badge.svg)](https://github.com/User-3090/herdr-win/actions/workflows/ci.yml) [![Windows nightly](https://github.com/User-3090/herdr-win/actions/workflows/windows-nightly.yml/badge.svg)](https://github.com/User-3090/herdr-win/actions/workflows/windows-nightly.yml) [![Rust 1.96.1](https://img.shields.io/badge/Rust-1.96.1-000000?logo=rust&logoColor=white)](https://github.com/User-3090/herdr-win/blob/master/rust-toolchain.toml) [![Upstream](https://img.shields.io/badge/upstream-ogulcancelik%2Fherdr-181717?logo=github)](https://github.com/ogulcancelik/herdr) [![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/User-3090/herdr-win/blob/master/LICENSE)

`herdr-win` publishes a native Windows x86_64 build by replaying a small, explicit patch queue on current upstream `master`. It is a distribution and patch control plane—not a separate product line—and keeps the Windows delta reviewable, replayable, and suitable for upstream integration.

[Install](#install-a-windows-nightly) · [Patch queue](#maintained-windows-delta) · [Upstream review](#for-upstream-maintainers) · [Nightlies](#how-nightlies-work) · [Contributing](#contributing) · [Upstream docs](https://herdr.dev/docs/)

> [!NOTE]
> General Herdr documentation, behavior, and issue ownership remain upstream. Fork identity appears only in repository, release, and update-channel presentation; the executable and runtime identity stay `herdr`. The explicit Windows behavior delta is mapped below.

## Identity and compatibility

Only the fork's repository and release-channel identity change. Runtime-facing names stay compatible with upstream:

| Surface | Name |
| --- | --- |
| Repository and nightly channel | `herdr-win` |
| Executable and command | `herdr.exe` / `herdr` |
| Cargo package | `herdr` |
| Configuration, state, sessions, sockets, and protocol | `herdr` |

You can switch between an upstream Herdr build and a herdr-win build without migrating configuration or learning a second command. Stop running sessions before manually replacing a portable executable.

## Install a Windows nightly

Nightlies currently target Windows x86_64. When the newest [herdr-win prerelease](https://github.com/User-3090/herdr-win/releases) includes `herdr-windows-x86_64-installer.exe`, use it for a normal per-user install. Its SHA-256 is published in the fork's [preview manifest](https://raw.githubusercontent.com/User-3090/herdr-win/master/website/preview.json); until that asset appears, use the portable ZIP below.

```powershell
$manifest = Invoke-RestMethod https://raw.githubusercontent.com/User-3090/herdr-win/master/website/preview.json -TimeoutSec 30
$asset = $manifest.assets.'windows-x86_64-installer'
if ($null -eq $asset) { throw "No managed installer is published yet; use the portable ZIP below" }
$installer = Join-Path $PWD 'herdr-windows-x86_64-installer.exe'
Invoke-WebRequest $asset.url -OutFile $installer -TimeoutSec 120
$actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -cne [string] $asset.sha256) { throw "herdr-win installer checksum mismatch" }
& $installer
```

The installer uses `%LOCALAPPDATA%\Programs\Herdr`, adds its stable `bin` directory to your user `PATH`, and registers Herdr in **Windows Settings → Apps → Installed apps**. The executable and command remain `herdr.exe` and `herdr`.

For a portable or manual install, download both:

- `herdr-windows-x86_64.zip`
- `herdr-windows-x86_64.zip.sha256`

Verify the archive in PowerShell:

```powershell
$archive = (Resolve-Path .\herdr-windows-x86_64.zip).Path
$checksum = (Resolve-Path .\herdr-windows-x86_64.zip.sha256).Path
$expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "herdr-win checksum mismatch" }
```

Extract the ZIP into a new, empty directory and keep the complete directory together. It contains `herdr.exe`, the pinned Microsoft ConPTY runtime, its integrity marker, and third-party notices. Then run `herdr.exe` directly or add that directory to your user `PATH`.

> [!WARNING]
> The Herdr executable and installer are not code-signed, so Windows may show a SmartScreen warning. Verify the manifest digest or ZIP sidecar before running either artifact. The bundled Microsoft ConPTY binaries are signature-checked during packaging.

### Automatic preview updates

The build reuses Herdr's existing preview update checks against the fork-owned nightly manifest. It checks at startup and every 30 minutes while running and shows Herdr's normal update-ready indicator when a newer build exists. Run `herdr update` from an ordinary PowerShell after detaching from Herdr; it downloads the immutable NSIS asset, verifies its SHA-256, and runs the installer silently without terminating active sessions.

If older managed sessions are still active, the update is reported as staged. Those sessions continue on their original runtime, and new launches switch atomically after the last old session exits. Running `herdr update` from a portable herdr-win ZIP similarly moves future launches to the managed installation. The manifest is generated from tested artifacts only after their immutable prerelease is published; a final independent gate downloads and verifies both Windows assets. There is no fallback to upstream update sources.

### Uninstall

Close all managed Herdr sessions, then uninstall **Herdr** from **Windows Settings → Apps → Installed apps**. The uninstaller refuses to remove an active installation and never terminates sessions. It removes the managed program, user `PATH` entry, and Installed Apps registration while preserving Herdr configuration and session data under `%USERPROFILE%\.herdr`.

## Maintained Windows delta

The release product delta is exactly the ordered mailbox queue in [`patches/delta/series`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/series). [`BASE`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/BASE) records the upstream commit used for the latest reviewed refresh.

| Patch | Review scope |
| --- | --- |
| [`0001`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/0001-windows-terminal-appearance.patch) | **Terminal appearance:** host appearance and color transport, cursor fidelity, terminal rendering, and Windows VTI input behavior. |
| [`0003`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/0003-windows-remote-attach.patch) | **Remote attach:** shared orchestration, the Windows SSH/named-pipe backend, bounded clipboard/drop image transport, and a small fork-specific Sandbox adapter. |
| [`0004`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/0004-windows-managed-distribution.patch) | **Managed Windows distribution:** deterministic ConPTY packaging, immutable runtimes and launcher leases, per-user NSIS install/update/uninstall, legacy migration, and fork-owned update sources. |

Because this channel publishes only a Windows executable, it cannot automatically install the matching nightly binary on a Linux or macOS remote. Use a pre-provisioned matching target or provide a matching build through `HERDR_REMOTE_BINARY` when attaching from a nightly.

See the [queue documentation](https://github.com/User-3090/herdr-win/blob/master/patches/delta/README.md) for its refresh policy. [`patches/upstream/`](https://github.com/User-3090/herdr-win/tree/master/patches/upstream) is a frozen legacy archive retained so existing patch links continue to work.

## For upstream maintainers

You do not need to infer product changes from fork branch history. The three mailboxes above are the complete maintained behavior delta:

1. start at the exact commit recorded by [`BASE`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/BASE);
2. apply the filenames from [`series`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/series) in order with `git am --3way`;
3. review each mailbox's rationale, full-index diff, tests, and documentation as one responsibility-oriented unit; and
4. use the replay and verification procedure in [`CONTRIBUTING.md`](https://github.com/User-3090/herdr-win/blob/master/CONTRIBUTING.md) to reproduce the queue on a fresh upstream checkout.

The mailboxes are review units, not a request to merge each one unchanged. Patch 0003 includes a fork-specific preinstalled-binary adapter for Herdr Sandbox, and patch 0004 contains fork-only distribution URLs; their generic remote and packaging improvements can be separated from that wiring if upstream adopts them. Repository branding, workflows, release manifests, and publication automation remain outside the product queue.

## How nightlies work

The scheduled workflow:

1. checks out the current upstream Herdr `master`;
2. applies `patches/delta/series` without resolving conflicts automatically;
3. runs pre-publication Windows formatting, lint, focused tests, ConPTY, installer, and runtime probes;
4. publishes an immutable portable ZIP and managed installer identified by both the upstream and herdr-win control revisions;
5. generates and pushes the preview manifest only after that release is verified; and
6. independently verifies that the public update feed exposes the tested build.

A replay, build, package, or publication failure prevents the subsequent release state. The final public-feed check can fail after the immutable prerelease and manifest commit already exist; that leaves the workflow failed for diagnosis rather than mutating published artifacts. Ordinary pushes do not build or publish binaries. For release purposes this repository is the control plane; the nightly always builds a fresh upstream checkout rather than treating a long-lived integration branch as release source.

## Documentation and issue routing

Use the [upstream documentation](https://herdr.dev/docs/) for the `herdr` CLI, configuration, agent integrations, and general behavior. Fork-specific behavior and limitations are documented here and in the maintained patch queue.

For a Windows-fork problem, open a [herdr-win issue](https://github.com/User-3090/herdr-win/issues) with the release tag, Windows version, terminal, shell, and a minimal reproduction. Reproduce a problem with an upstream build before reporting it upstream; fork-only failures belong here.

## Contributing

Read [`CONTRIBUTING.md`](https://github.com/User-3090/herdr-win/blob/master/CONTRIBUTING.md) before changing the queue or automation. AI agents must also follow [`AGENTS.md`](https://github.com/User-3090/herdr-win/blob/master/AGENTS.md).

## Attribution and license

Herdr is created and maintained upstream by [Can Çelik](https://github.com/ogulcancelik). Consider [sponsoring upstream Herdr](https://github.com/sponsors/ogulcancelik) if the project is useful to you.

herdr-win is distributed under the upstream [Apache License 2.0](https://github.com/User-3090/herdr-win/blob/master/LICENSE).
