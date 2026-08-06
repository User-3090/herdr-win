# herdr-win

**A native Windows distribution of [Herdr](https://github.com/herdrdev/herdr), maintained as a small, reviewable patch queue, not a permanent fork.**

[![Patch replay](https://github.com/hdosys/herdr-win/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/hdosys/herdr-win/actions/workflows/ci.yml) [![Candidate build](https://github.com/hdosys/herdr-win/actions/workflows/release.yml/badge.svg?branch=master)](https://github.com/hdosys/herdr-win/actions/workflows/release.yml) [![Rust 1.96.1](https://img.shields.io/badge/Rust-1.96.1-000000?logo=rust&logoColor=white)](https://github.com/hdosys/herdr-win/blob/master/rust-toolchain.toml) [![Built with Herdr Sandbox](https://img.shields.io/badge/built%20with-Herdr%20Sandbox-0078D4?logo=windows11&logoColor=white)](https://github.com/hdosys/herdr-sandbox) [![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/hdosys/herdr-win/blob/master/LICENSE)

`herdr-win` is an unofficial, upstream-first delivery lane for Herdr on Windows. It keeps the normal `herdr` command and workflow, adds Windows behavior not yet available in an upstream stable release, and publishes tested snapshots from an exact reviewed Herdr release plus the ordered maintained patch queue.

[Why it exists](#why-it-exists) · [What it adds](#what-differs-from-upstream) · [Install](#install) · [Patch flow](#how-the-patch-queue-works) · [Upstream review](#for-upstream-maintainers) · [Maintaining](#maintaining-the-project) · [Herdr Sandbox](#sister-project-herdr-sandbox)

> [!NOTE]
> Upstream Herdr owns the general CLI, configuration, integrations, and product documentation. This repository owns only its Windows-focused delta and distribution. Reproduce general issues with upstream Herdr before reporting them here.

## Why it exists

Herdr already runs on Windows, but a good Windows release needs more than a binary that compiles. Terminal fidelity, remote attachment, safe packaging, updates, and native verification all need clear ownership.

This repository provides that focused delivery path:

- **Useful Windows behavior now:** fixes can ship without turning the fork into a separate product.
- **A visible delta:** every retained change belongs to one reviewable mailbox instead of disappearing into branch history.
- **An upstream route:** code that lands upstream is removed from the queue rather than maintained twice.
- **Reproducible snapshots:** source, patch order, build identity, artifacts, and SHA-256 digests stay connected.

## What differs from upstream

The table is intentionally capability-level. The patch files contain the exact implementation and tests.

| Area | Status | What this repository contributes |
| --- | --- | --- |
| Native ConPTY foundation | ✅ **Upstreamed in Herdr v0.6.9** | Herdr v0.8.0 added the modern app-local ConPTY packaging that herdr-win now reuses instead of carrying a duplicate foundation. |
| Terminal fidelity | **Maintained here** · [`0001`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/0001-windows-terminal-appearance.patch) | Windows appearance, color and cursor fidelity, rendering, and VTI input behavior. |
| Windows remote attach and image bridge | **Partly merged upstream after v0.8.0, release pending** · [#2329](https://github.com/herdrdev/herdr/pull/2329) · [`0003`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/0003-windows-remote-attach.patch) | Upstream master now includes Windows client attach to Linux/macOS and the image bridge. herdr-win retains Windows remote-host attach and additional named-pipe/backpressure coverage until the next stable refresh minimizes the mailbox. |
| Managed Windows snapshots | **Maintained here** · [`0004`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/0004-windows-managed-distribution.patch) | Verified Windows packages, per-user setup, portable archives, package-manager update ownership, and safe runtime handoff. |
| OpenCode lifecycle reporting | **Maintained here** · [`0005`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/0005-opencode-retry-notifications.patch) | Retry-aware status correlation so active retries stay quiet and terminal failures remain visible. |
| Runtime downloads | **Maintained here** · [`0006`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/0006-harden-curl-transfers.patch) | Cross-platform `curl` transfers ignore user configuration and permit only bounded TLS 1.2+ HTTPS requests and redirects. |

Upstream PR #2329 merged after v0.8.0 and has not shipped in a stable release yet. Mailbox `0003` therefore remains in the current queue; at the next stable refresh, it can shrink to Windows-host attach and the additional bridge hardening. The original implementation builds on [nsxdavid's `feat/windows-remote-attach` work](https://github.com/nsxdavid/herdr/tree/feat/windows-remote-attach).

## Sister project: Herdr Sandbox

herdr-win is developed and validated with [**Herdr Sandbox**](https://github.com/hdosys/herdr-sandbox), a disposable native Windows development environment for coding agents. It provides the clean Windows toolchains and realistic native boundary used to build and test this fork; it is a sister project, not a runtime dependency.

## How the patch queue works

```mermaid
flowchart LR
    U["Upstream Herdr<br/>v0.8.0"] --> B["BASE<br/>346411fa21af"]

    subgraph Q["patches/delta/series"]
        direction LR
        P1["0001<br/>Terminal fidelity"] --> P3["0003<br/>Remote attach"]
        P3 --> P4["0004<br/>Windows distribution"]
        P4 --> P5["0005<br/>OpenCode lifecycle"]
        P5 --> P6["0006<br/>Hardened downloads"]
    end

    B --> P1
    P6 --> R["Fresh replay"]
    R --> G["Native + cross-platform gates"]
    G --> A["Setup · ZIP · digests"]
```

[`patches/delta/BASE`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/BASE) records the exact upstream stable commit. [`series`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/series) is the only application order. Each patch is a full-index, binary-safe mailbox with one logical responsibility.

An upstream refresh is deliberate: select the latest stable release, replay the complete queue, remove behavior upstream now owns, regenerate changed mailboxes, and verify a fresh replay. `BASE` never follows upstream `master` automatically.

## Install

Windows x86_64 is the managed distribution target. Each release also carries matching Linux and macOS binaries for remote endpoints that must speak the same wire protocol.

### Setup (recommended)

<p align="center">
  <img src="https://raw.githubusercontent.com/hdosys/herdr-win/master/docs/assets/herdr-win-setup-welcome.png" alt="Herdr Win setup welcome page">
</p>

Download the newest `herdr-win_v<version>_windows_amd64_setup.exe` from [Releases](https://github.com/hdosys/herdr-win/releases) and run it. Setup installs for the current user without administrator access, adds `herdr` to the user `PATH`, and registers an uninstaller. Open a new terminal and run:

```powershell
herdr
```

For setup downloaded directly from Releases, use `herdr update` from an ordinary terminal after detaching from active Herdr sessions. Updates preserve running sessions and activate the new verified snapshot when it is safe. A WinGet-owned installation instead updates through:

```powershell
winget upgrade --id hdosys.herdr-win --exact --source winget
```

GitHub may publish a snapshot before the WinGet catalog finishes accepting it. A WinGet-owned copy shows an update only after the official `winget` source contains that exact release version, so its update action always points to installable bytes.

Uninstall from **Windows Settings → Apps → Installed apps**. Settings are preserved unless you explicitly choose to remove them. Uninstall never terminates active Herdr sessions or removes unowned or unsafe content; it stops or preserves the blocked residue and explains the required action.

### Verify the download

GitHub records a SHA-256 digest for every immutable release asset. Before running setup, verify the downloaded file against the `digest` for the same filename in that tagged release's GitHub metadata.

### Portable Windows ZIP

The release also includes `herdr-win_v<version>_windows_amd64.zip`. Extract the complete archive into one directory and run `herdr.exe`.

> [!WARNING]
> The Herdr executable and setup are currently unsigned, so Windows may show a SmartScreen warning. Download release artifacts only from this repository.

### Matching Linux and macOS binaries

Each release includes raw `linux_amd64`, `linux_arm64`, `macos_amd64`, and `macos_arm64` executables. They are compatibility companions for remote hosts, not managed installers.

Use matching binaries from the same herdr-win release on every endpoint. Independently released official builds are not guaranteed to use the same wire protocol.

For general commands, configuration, and agent integrations, use the [official Herdr documentation](https://herdr.dev/docs/).

## For upstream maintainers

Thank you for the native Windows foundation and the remote-client work merged in [#2329](https://github.com/herdrdev/herdr/pull/2329). herdr-win exists to make remaining Windows behavior easy to inspect, test, and remove from this fork as equivalent support lands upstream. The Windows remote-host follow-up is tracked in [Discussion #2409](https://github.com/herdrdev/herdr/discussions/2409).

The five files in `patches/delta/series` are the complete maintained product delta. Each is self-contained, so its behavior does not need to be reconstructed from this fork's development history.

1. Start at the exact commit in [`BASE`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/BASE).
2. Apply [`series`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/series) in order with `git am --3way`.
3. Review each mailbox as one responsibility-oriented change with its implementation, tests, and documentation.
4. Follow [`CONTRIBUTING.md`](https://github.com/hdosys/herdr-win/blob/master/CONTRIBUTING.md) to reproduce the replay and verification gates.

The mailboxes are offered as focused evidence and acceptance tests, not an all-or-nothing merge request. Upstream can split or reimplement them along its own ownership boundaries; once equivalent behavior ships, herdr-win removes it. Fork branding, release workflows, and publication state stay outside the product queue.

## Maintaining the project

Refresh and release are intentionally separate manual operations:

- **Refresh:** select and review a stable upstream release, then replay and minimize the queue.
- **Build:** replay recorded `BASE`, run the complete gates, and retain one candidate with provenance and checksums.
- **Promote:** publish those exact retained bytes without rebuilding or repackaging them.

Ordinary pushes do not publish binaries.

| Need | Canonical owner |
| --- | --- |
| User-visible fork behavior | [`PRODUCT.md`](https://github.com/hdosys/herdr-win/blob/master/PRODUCT.md) |
| Technical boundaries | [`ARCHITECTURE.md`](https://github.com/hdosys/herdr-win/blob/master/ARCHITECTURE.md) |
| Patch ownership and refresh policy | [`patches/delta/README.md`](https://github.com/hdosys/herdr-win/blob/master/patches/delta/README.md) |
| Replay, verification, and release procedure | [`CONTRIBUTING.md`](https://github.com/hdosys/herdr-win/blob/master/CONTRIBUTING.md) |
| Open work | [`BACKLOG.md`](https://github.com/hdosys/herdr-win/blob/master/BACKLOG.md) |

## Issues and contributions

- Use [upstream Herdr](https://github.com/herdrdev/herdr) for general product behavior that reproduces with an official upstream build.
- Use [herdr-win issues](https://github.com/hdosys/herdr-win/issues) for this distribution's artifacts, update feed, workflows, or maintained patches.
- Read [`CONTRIBUTING.md`](https://github.com/hdosys/herdr-win/blob/master/CONTRIBUTING.md) before changing the queue or release automation.

## Credits and license

Herdr is created and maintained upstream by [Can Çelik](https://github.com/ogulcancelik). herdr-win is distributed under the [Apache License 2.0](https://github.com/hdosys/herdr-win/blob/master/LICENSE).
