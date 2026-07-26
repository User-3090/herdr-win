# herdr-win

**An unofficial, upstream-first Windows build of [Herdr](https://github.com/ogulcancelik/herdr).**

[Windows nightlies](https://github.com/User-3090/herdr-win/releases) ·
[upstream Herdr](https://github.com/ogulcancelik/herdr) ·
[maintained delta](patches/delta/README.md)

`herdr-win` keeps a small set of Windows-focused changes replayable on top of
the latest upstream `master`. It is meant to be a friendly drop-in build for
people using Herdr natively on Windows, not a separate product or a competing
upstream.

## The repository is `herdr-win`; the program is `herdr`

Only the fork's repository and release-channel identity change. Runtime-facing
names stay compatible with upstream:

| Surface | Name |
| --- | --- |
| Repository and nightly channel | `herdr-win` |
| Executable and command | `herdr.exe` / `herdr` |
| Cargo package | `herdr` |
| Configuration, state, sessions, sockets, and protocol | `herdr` |

You can switch between an upstream Herdr build and a herdr-win build without
migrating configuration or learning a second command. Stop running sessions
before replacing the executable.

## Install a Windows nightly

Nightlies currently target Windows x86_64. From the newest
[herdr-win prerelease](https://github.com/User-3090/herdr-win/releases), download
both:

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

Extract the ZIP into a new, empty directory and keep the complete directory
together. It contains `herdr.exe`, the pinned Microsoft ConPTY runtime, its
integrity marker, and third-party notices. Then run `herdr.exe` directly or add
that directory to your user `PATH`.

The fork executable is not code-signed, so Windows may show a SmartScreen
warning. The bundled Microsoft ConPTY binaries are signature-checked during
packaging.

The first herdr-win install is manual. After that, the build reuses Herdr's
existing preview update path against the fork-owned nightly manifest. It checks
at startup and every 30 minutes while running, shows Herdr's normal update-ready
indicator when a newer build exists, and installs the verified fork ZIP through
`herdr update`. The manifest advances only after the Windows nightly passes and
its immutable prerelease is published.

The installer at `herdr.dev` still belongs to upstream. Use the fork release for
the initial install, and run `herdr update` outside Herdr after detaching when an
update is ready.

## What the maintained delta covers

The canonical queue is intentionally small and grouped by responsibility:

1. Windows terminal appearance, input, cursor, and color behavior.
2. Native Windows notifications and reliable audio playback.
3. Windows remote attach plus bounded remote clipboard-image transport.
4. Deterministic ConPTY packaging, fork-owned updates, and hardened PowerShell
   installation checks.

Because this channel publishes only a Windows executable, it cannot
automatically install the matching nightly binary on a Linux or macOS remote.
Use a pre-provisioned matching target or provide a matching build through
`HERDR_REMOTE_BINARY` when attaching from a nightly.

See [`patches/delta/README.md`](patches/delta/README.md) for the exact queue and
refresh policy. [`patches/upstream/`](patches/upstream/README.md) is a frozen
legacy archive retained so existing patch links continue to work.

## How nightlies work

The scheduled workflow:

1. checks out the current upstream Herdr `master`;
2. applies `patches/delta/series` without resolving conflicts automatically;
3. runs Windows formatting, lint, focused tests, ConPTY, installer, and runtime
   probes;
4. publishes an immutable prerelease identified by both the upstream and
   herdr-win control revisions;
5. advances the fork preview manifest only after that release is verified.

If a patch no longer applies or a gate fails, no release is published. Ordinary
pushes do not build or publish binaries. For release purposes this repository is
the control plane; the nightly always builds a fresh upstream checkout rather
than treating a long-lived integration branch as release source.

## Documentation and support

Use the [upstream documentation](https://herdr.dev/docs/) for the `herdr` CLI,
configuration, agent integrations, and general behavior. Fork-specific behavior
and limitations are documented here and in the maintained patch queue.

When reporting a problem, include the herdr-win release tag, Windows version,
terminal, shell, and a minimal reproduction. Please reproduce a problem with an
upstream build before reporting it upstream; fork-only failures belong in this
repository.

## Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before changing the queue or automation.
AI agents must also follow [`AGENTS.md`](AGENTS.md).

## Attribution and license

Herdr is created and maintained upstream by
[Can Çelik](https://github.com/ogulcancelik). Consider
[sponsoring upstream Herdr](https://github.com/sponsors/ogulcancelik) if the
project is useful to you.

herdr-win is distributed under the upstream [Apache License 2.0](LICENSE).
