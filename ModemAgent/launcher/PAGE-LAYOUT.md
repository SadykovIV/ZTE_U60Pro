# Additional page selection

`/data/zte-launcher/page-layout.conf` is separate from the Info metrics layout.
It contains exact ASCII bytes, at most 128 bytes:

```text
ZTE_LAUNCHER_PAGES_V1
info
vpn
esim
```

After the header there are zero to three unique lines, in display order. The
only names are `info`, `vpn`, and `esim`. Every line, including the last, ends
with LF. Header only means no additional pages; the two stock pages remain.
Blank lines, CRLF, duplicates, whitespace and unknown names are invalid.

The C structure is `{ unsigned char count; unsigned char ids[3]; }`, with
`PAGE_INFO=0`, `PAGE_VPN=1`, and `PAGE_ESIM=2`. A missing file in a trusted
directory returns `PAGE_LAYOUT_DEFAULT` (2) and all three pages in the order
above. A valid file returns `PAGE_LAYOUT_CONFIG` (1). Unsafe paths, permissions
or malformed content return `PAGE_LAYOUT_INVALID` (0) and count zero. The
reader never writes. It uses descriptor-relative no-follow opens, validates
root ownership and non-writable directory parents, and requires a root-owned
0600 regular file with one hard link.

The source installer accepts optional `stage/page-layout.conf`. The same exact
grammar, size, ownership, mode and hard-link requirements apply. When omitted,
the existing file is preserved byte for byte; absence remains absence. When
present, the staged selection is copied into the verified replacement before
the directory swap. Rollback restores the prior directory and its prior
selection. Invalid existing or staged data causes preflight/apply to fail
before recovery or installed-state changes. An invalid old selection also
prevents rollback from restoring that directory; the transaction is retained.

Checks: `tests/page_layout_test.c` runs under ASan/UBSan and covers all 16
ordered subsets plus malformed input and filesystem guards.
`tests/page_layout_installer_test.py` runs the source installer in isolated
OpenWrt fixtures: 18 cases including staged replacement, read-only preflight,
rollback, invalid configuration and interrupted updates. No device is used.
