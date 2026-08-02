# herdr-win maintained delta

This is the canonical product delta applied by the manually dispatched herdr-win
release workflow on top of the reviewed [`ogulcancelik/herdr`](https://github.com/ogulcancelik/herdr)
stable-release commit recorded in `BASE`.

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

- `BASE` records the exact commit behind the latest non-draft, non-prerelease
  upstream stable release selected during the latest explicit manual refresh.
- `series` is the only release application order.
- `*.patch` files are full-index, binary-safe `git format-patch` mailboxes.

Repository branding, GitHub Actions, and release orchestration are control-plane
files and do not belong in this product patch queue.

## Refreshing the queue

1. Query the official latest stable release, fetch and peel its `v<version>` tag,
   verify it is neither draft nor prerelease, and start a clean branch at that
   exact commit.
2. Apply `series` in order with `git am --3way`.
3. Resolve upstream drift in the patch that owns the behavior.
4. Keep one reviewed commit per logical patch and regenerate its mailbox with
   `git format-patch --full-index --binary`.
5. Preserve the stable filename, update `BASE` only after review, replay the
   complete queue on a fresh checkout of that tagged stable commit, verify the tag
   matches Cargo version, and run the relevant verification.

Validate the control-plane inventory with:

```powershell
python -m unittest scripts.test_delta_patches scripts.test_upstream_patches
```

Release replay never resolves conflicts automatically. A conflict means the
owning patch must be refreshed and reviewed.
