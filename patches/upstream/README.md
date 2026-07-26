# Legacy upstream patch archive

This directory is retained as a compatibility archive because external posts
link directly to its mailbox files. Do not remove, rename, or repurpose those
files. `index.json` and `series` describe the historical fork patch set at the
time this archive was frozen.

The maintained herdr-win delta now lives in [`../delta/`](../delta/). Nightly
builds do not apply this legacy archive.

## Stable-link policy

- Keep every existing `*.patch` URL valid.
- Do not refresh these mailboxes onto a newer upstream base.
- Correct historical metadata only when a broken link or malformed archive
  requires it.
- Add current Windows work to `patches/delta/`, not here.

## Files

- `index.json` contains the historical logical-fix metadata.
- `series` preserves the historical mailbox order.
- `*.patch` files are full-index, binary-safe mailboxes.
- `scripts/test_upstream_patches.py` validates this frozen inventory offline.

Git history remains the authoritative record for when a legacy patch was
introduced, superseded, or incorporated upstream.
