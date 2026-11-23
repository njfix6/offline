// swift-tools-version:6.1
import PackageDescription

// OfflineKit holds everything except the app's entry point.
//
//   CArgon2      Vendored Argon2 reference implementation (backup key derivation).
//   OfflineCore  Vault, Store, Backup, Markdown parsing. No UI.
//   OfflineKit   Editor, Lock, UI (AppKit + SwiftUI).
//
// The only third-party code is GRDB (vendored, built against SQLCipher) and
// the Argon2 reference sources. Nothing here may import a networking API.
let package = Package(
    name: "OfflineKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OfflineKit", targets: ["OfflineKit"]),
        .library(name: "OfflineCore", targets: ["OfflineCore"]),
    ],
    dependencies: [
        .package(path: "../Vendor/GRDB.swift"),
    ],
    targets: [
        .target(
            name: "CArgon2",
            exclude: ["LICENSE", "VENDORED.md"],
            cSettings: [.define("ARGON2_NO_THREADS")]
        ),
        .target(
            name: "OfflineCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "CArgon2",
            ]
        ),
        .target(
            name: "OfflineKit",
            dependencies: ["OfflineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OfflineCoreTests",
            dependencies: ["OfflineCore"]
        ),
        .testTarget(
            name: "OfflineKitTests",
            dependencies: ["OfflineKit", "OfflineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
