# herdr-win

**An unofficial, upstream-first Windows distribution of [Herdr](https://github.com/ogulcancelik/herdr).**

[![Patch replay](https://github.com/User-3090/herdr-win/actions/workflows/ci.yml/badge.svg)](https://github.com/User-3090/herdr-win/actions/workflows/ci.yml) [![Windows release](https://github.com/User-3090/herdr-win/actions/workflows/windows-nightly.yml/badge.svg)](https://github.com/User-3090/herdr-win/actions/workflows/windows-nightly.yml) [![Rust 1.96.1](https://img.shields.io/badge/Rust-1.96.1-000000?logo=rust&logoColor=white)](https://github.com/User-3090/herdr-win/blob/master/rust-toolchain.toml) [![Upstream](https://img.shields.io/badge/upstream-ogulcancelik%2Fherdr-181717?logo=github)](https://github.com/ogulcancelik/herdr) [![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](https://github.com/User-3090/herdr-win/blob/master/LICENSE)

`herdr-win` publishes native snapshots by replaying a small, explicit patch queue on the reviewed stable-release commit recorded in `patches/delta/BASE`. Each explicit manual refresh selects the latest non-draft, non-prerelease upstream release; between refreshes that stable base remains pinned. Windows x86_64 is the first supported target; other upstream-supported platforms are planned. Upstream refreshes and releases are both manual, and no scheduled workflow rebases, tests, or publishes current upstream. It is a distribution and patch control plane—not a separate product line—and keeps the delta reviewable, replayable, and suitable for upstream integration.

[Install](#install-a-windows-snapshot) · [Patch queue](#maintained-windows-delta) · [Upstream review](#for-upstream-maintainers) · [Releases](#how-manual-releases-work) · [Contributing](#contributing) · [Upstream docs](https://herdr.dev/docs/)

> [!NOTE]
> General Herdr documentation, behavior, and issue ownership remain upstream. Fork identity appears only in repository, release, and update-channel presentation; the executable and runtime identity stay `herdr`. The explicit Windows behavior delta is mapped below.

## Identity and compatibility

Only the fork's repository and release-channel identity change. Runtime-facing names stay compatible with upstream:

| Surface | Name |
| --- | --- |
| Repository and snapshot releases | `herdr-win` |
| Executable and command | `herdr.exe` / `herdr` |
| Cargo package | `herdr` |
| Configuration, state, sessions, sockets, and protocol | `herdr` |

You can switch between an upstream Herdr build and a herdr-win build without migrating configuration or learning a second command. Stop running sessions before manually replacing a portable executable.

## Install a Windows snapshot

Snapshots currently target Windows amd64. When the newest [herdr-win prerelease](https://github.com/User-3090/herdr-win/releases) includes `herdr-win_v<YYYY.MM.DD.N>_windows_amd64_setup.exe`, use it for a normal per-user install. Its SHA-256 is published in the fork's [update manifest](https://raw.githubusercontent.com/User-3090/herdr-win/master/website/preview.json); until that asset appears, use the portable ZIP below.

```powershell
$manifest = Invoke-RestMethod https://raw.githubusercontent.com/User-3090/herdr-win/master/website/preview.json -TimeoutSec 30
$asset = $manifest.assets.'windows-x86_64-installer'
if ($null -eq $asset) { throw "No managed installer is published yet; use the portable ZIP below" }
$setupName = [IO.Path]::GetFileName(([Uri][string]$asset.url).AbsolutePath)
$setup = Join-Path $PWD $setupName
Invoke-WebRequest $asset.url -OutFile $setup -TimeoutSec 120
$actual = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -cne [string] $asset.sha256) { throw "herdr-win setup checksum mismatch" }
& $setup
```

The English-only, keyboard-operable Windows setup uses native-DPI Herdr Win artwork on its Welcome and Finish pages, presents the Apache-2.0 license before modifying files, installs to `%LOCALAPPDATA%\Programs\Herdr` without administrator privileges, adds its stable `bin` directory to your user `PATH`, and registers Herdr in **Windows Settings → Apps → Installed apps**. The same license remains available as `LICENSE.txt`. Setup copies upstream's canonical agent skill to `%USERPROFILE%\.agents\skills\herdr\SKILL.md` and, when Claude Code is detected, to its configured or default `.claude\skills\herdr\SKILL.md`. Install and update overwrite only `SKILL.md`; every sibling file and directory remains untouched. The executable and command remain `herdr.exe` and `herdr`.

Setup updates only an exact current managed installation. If it reports an incompatible existing installation, uninstall **Herdr** from **Windows Settings → Apps → Installed apps**, then run setup again. Setup preserves that directory and does not migrate, back up, or remove it.

For a portable or manual install, download both:

- `herdr-win_v<YYYY.MM.DD.N>_windows_amd64.zip`
- `herdr-win_v<YYYY.MM.DD.N>_windows_amd64.zip.sha256`

Verify the archive in PowerShell:

```powershell
$archive = (Resolve-Path .\herdr-win_v*_windows_amd64.zip).Path
$checksum = (Resolve-Path "$archive.sha256").Path
$expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "herdr-win checksum mismatch" }
```

Extract the ZIP into a new, empty directory and keep the complete directory together. It contains `herdr.exe`, the pinned Microsoft ConPTY runtime, its integrity marker, and third-party notices. Then run `herdr.exe` directly or add that directory to your user `PATH`.

> [!WARNING]
> The Herdr executable and setup are not code-signed, so Windows may show a SmartScreen warning. Verify the manifest digest or ZIP sidecar before running either artifact. The bundled Microsoft ConPTY binaries are signature-checked during packaging.

### Automatic snapshot updates

The runtime reuses Herdr's existing `preview` update mechanism, but it reads only the fork-owned manifest and assets. herdr-win calls these artifacts **snapshots** to avoid implying that they correspond to upstream's separate preview releases. It checks at startup and every 30 minutes while running and shows Herdr's normal update-ready indicator when a newer snapshot exists. Run `herdr update` from an ordinary PowerShell after detaching from Herdr; it downloads the immutable NSIS asset, verifies its SHA-256, and runs setup silently without terminating active sessions.

If older managed sessions are still active, the update is reported as staged. Those sessions continue on their original runtime, and new launches switch atomically after the last old session exits. Running `herdr update` from a portable herdr-win ZIP similarly moves future launches to the managed installation. The manifest is generated from tested artifacts only after their immutable prerelease is published; a final independent gate downloads and verifies both Windows assets. There is no fallback to upstream update sources.

### Uninstall

Close all managed Herdr sessions, then uninstall **Herdr** from **Windows Settings → Apps → Installed apps**. The uninstaller refuses to remove an active installation and never terminates sessions. It removes the managed program, user `PATH` entry, Installed Apps registration, and `SKILL.md` from the managed universal and Claude skill locations even if that file was edited. Every sibling remains untouched, and the `herdr` skill directory is removed only when empty. **Remove Herdr settings and session data** is clear by default, preserving `%USERPROFILE%\.herdr` for a later installation unless you select it. Silent uninstall also preserves settings by default; pass `/REMOVE_SETTINGS` to delete them explicitly.

## Maintained Windows delta

The release product delta is exactly the ordered mailbox queue in [`patches/delta/series`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/series). [`BASE`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/BASE) records the exact upstream stable-release commit selected during the latest reviewed manual refresh.

| Patch | Review scope |
| --- | --- |
| [`0001`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/0001-windows-terminal-appearance.patch) | **Terminal appearance:** host appearance and color transport, cursor fidelity, terminal rendering, and Windows VTI input behavior. |
| [`0003`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/0003-windows-remote-attach.patch) | **Remote attach:** shared orchestration, the Windows SSH/named-pipe backend, bounded clipboard/drop image transport, and a small fork-specific Sandbox adapter. |
| [`0004`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/0004-windows-managed-distribution.patch) | **Managed Windows distribution:** deterministic ConPTY packaging, immutable runtimes and launcher leases, strict per-user NSIS install/update/uninstall, and fork-owned update sources. |
| [`0005`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/0005-opencode-retry-notifications.patch) | **OpenCode lifecycle:** correlate errors with explicit retry and idle events so active retries stay quiet while terminal failures remain actionable. |

Until matching platform artifacts are implemented, this channel cannot automatically install the corresponding snapshot binary on a Linux or macOS remote. Use a pre-provisioned matching target or provide a matching build through `HERDR_REMOTE_BINARY` when attaching from a snapshot.

See the [queue documentation](https://github.com/User-3090/herdr-win/blob/master/patches/delta/README.md) for its refresh policy. [`patches/upstream/`](https://github.com/User-3090/herdr-win/tree/master/patches/upstream) is a frozen legacy archive retained so existing patch links continue to work.

## For upstream maintainers

You do not need to infer product changes from fork branch history. The four mailboxes above are the complete maintained behavior delta:

1. start at the exact commit recorded by [`BASE`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/BASE);
2. apply the filenames from [`series`](https://github.com/User-3090/herdr-win/blob/master/patches/delta/series) in order with `git am --3way`;
3. review each mailbox's rationale, full-index diff, tests, and documentation as one responsibility-oriented unit; and
4. use the replay and verification procedure in [`CONTRIBUTING.md`](https://github.com/User-3090/herdr-win/blob/master/CONTRIBUTING.md) to reproduce the queue on a fresh upstream checkout.

The mailboxes are review units, not a request to merge each one unchanged. Patch 0003 includes a fork-specific preinstalled-binary adapter for Herdr Sandbox, and patch 0004 contains fork-only distribution URLs; their generic remote and packaging improvements can be separated from that wiring if upstream adopts them. Repository branding, workflows, release manifests, and publication automation remain outside the product queue.

## How manual releases work

The manually dispatched workflow takes one herdr-win CalVer `YYYY.MM.DD.N`, then:

1. checks out the reviewed upstream stable-release commit recorded in `BASE` and verifies its `v<Cargo version>` tag;
2. applies `patches/delta/series` without resolving conflicts automatically;
3. runs pre-publication Windows formatting, lint, focused tests, ConPTY, installer, and runtime probes;
4. publishes immutable `herdr-win_v<CalVer>_windows_amd64.zip` and `herdr-win_v<CalVer>_windows_amd64_setup.exe` assets identified by both the upstream and herdr-win control revisions, with release title `herdr-win v<CalVer> (Herdr v<upstream-version>)`;
5. generates and pushes the preview manifest only after that release is verified; and
6. independently verifies that the public update feed exposes the tested build.

CalVer is the human herdr-win release identity; the release title, notes, and setup metadata visibly pair it with the stable upstream Herdr version while machine-consumed filenames remain compatible. Source/control hashes remain exact provenance. The workflow never selects current upstream `master`, updates `BASE`, or rewrites the maintained queue. Selecting the latest stable release and refreshing the queue is a separate explicit manual maintenance operation.

A replay, build, package, or publication failure prevents the subsequent release state. The final public-feed check can fail after the immutable prerelease and manifest commit already exist; that leaves the workflow failed for diagnosis rather than mutating published artifacts. Ordinary pushes do not build or publish binaries. For release purposes this repository is the control plane; every manual release builds a fresh checkout of recorded `BASE` rather than treating a long-lived integration branch as release source.

## Documentation and issue routing

Use the [upstream documentation](https://herdr.dev/docs/) for the `herdr` CLI, configuration, agent integrations, and general behavior. Fork-specific behavior and limitations are documented here and in the maintained patch queue.

For a Windows-fork problem, open a [herdr-win issue](https://github.com/User-3090/herdr-win/issues) with the release tag, Windows version, terminal, shell, and a minimal reproduction. Reproduce a problem with an upstream build before reporting it upstream; fork-only failures belong here.

## Contributing

Read [`CONTRIBUTING.md`](https://github.com/User-3090/herdr-win/blob/master/CONTRIBUTING.md) before changing the queue or automation. AI agents must also follow [`AGENTS.md`](https://github.com/User-3090/herdr-win/blob/master/AGENTS.md).

## Attribution and license

Herdr is created and maintained upstream by [Can Çelik](https://github.com/ogulcancelik). Consider [sponsoring upstream Herdr](https://github.com/sponsors/ogulcancelik) if the project is useful to you.

herdr-win is distributed under the upstream [Apache License 2.0](https://github.com/User-3090/herdr-win/blob/master/LICENSE).
