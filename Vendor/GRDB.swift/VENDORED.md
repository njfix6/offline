# Vendored GRDB

- Upstream: https://github.com/groue/GRDB.swift
- Tag: v7.12.0
- Commit: 92a554cd0d5e8d67cb18993c6054e73fe42c066c
- SQLCipher: https://github.com/sqlcipher/SQLCipher.swift 4.20.0 (official prebuilt xcframework, checksum-pinned by its manifest)

The `GRDB/` and `Sources/GRDBSQLCipher/` directories are byte-for-byte copies
of upstream at the commit above (minus `Documentation.docc`). Only
`Package.swift` differs: it is upstream's manifest with the "GRDB+SQLCipher"
edits its own comments describe. Regenerate with `Scripts/vendor-grdb.sh`.
