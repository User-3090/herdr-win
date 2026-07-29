# herdr-win maintained delta

This is the canonical product delta applied by the herdr-win nightly build on
top of the latest [`ogulcancelik/herdr`](https://github.com/ogulcancelik/herdr)
`master` branch.

The queue intentionally contains a few coarse, logical feature patches rather
than one monolith or a patch for every development commit:

1. Windows terminal appearance.
2. Windows remote attach and image transport.
3. Windows managed distribution, installer lifecycle, and checked-in fork update handling.
4. OpenCode retry lifecycle correlation.

When a feature evolves, refresh its existing mailbox in place. Add a new patch
only when the change has a genuinely independent owner, verification plan, and
upstream integration path. This keeps replay conflicts localized without
turning the queue into task history.

## Files

- `BASE` records the upstream commit used for the latest reviewed refresh.
- `series` is the only nightly application order.
- `*.patch` files are full-index, binary-safe `git format-patch` mailboxes.

Repository branding, GitHub Actions, and release orchestration are control-plane
files and do not belong in this product patch queue.

## Refreshing the queue

1. Start a clean branch at the latest upstream `master`.
2. Apply `series` in order with `git am --3way`.
3. Resolve upstream drift in the patch that owns the behavior.
4. Keep one reviewed commit per logical patch and regenerate its mailbox with
   `git format-patch --full-index --binary`.
5. Preserve the stable filename, update `BASE`, replay the complete queue on a
   fresh upstream checkout, and run the relevant verification.

Validate the control-plane inventory with:

```powershell
python -m unittest scripts.test_delta_patches scripts.test_upstream_patches
```

Nightly replay never resolves conflicts automatically. A conflict means the
owning patch must be refreshed and reviewed.
