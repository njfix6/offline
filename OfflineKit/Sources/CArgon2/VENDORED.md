# Vendored Argon2 reference implementation

- Upstream: https://github.com/P-H-C/phc-winner-argon2
- Tag: 20190702 (commit 62358ba2123abd17fccf2a108a301d4b52c01a7c)
- License: CC0 1.0 / Apache 2.0 (see LICENSE)

Unmodified copies of the portable reference sources (`ref.c`, not the
SSE-specific `opt.c`, so the same code runs on Apple Silicon and Intel).
Built single-threaded (`ARGON2_NO_THREADS`). Used only to derive the key for
`.offlinebackup` files from the user's passphrase (Argon2id).
