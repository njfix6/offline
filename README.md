# Offline

A private, local-only notes app for the Mac.

Offline keeps plain Markdown notes in one encrypted file on your Mac. It has no
network access, no accounts and no sync, and it gives Apple Intelligence, Siri,
Spotlight and screen capture nothing to read. Every protection is on from the
first launch, and there is no setting that turns one off.

- **Platform:** macOS 15 (Sequoia) or later, Apple Silicon and Intel
- **Built with:** Swift 6, SwiftUI and AppKit
- **Price:** free and open source (MIT)

> **Status: early.** The storage, search, backup and Markdown code is covered by
> unit tests. The checks that need a real Mac (Touch ID, Writing Tools, screen
> capture, Siri, Little Snitch) are listed in [VERIFY.md](VERIFY.md) and must be
> run by hand before trusting a build with real notes.

## What it does

- Three panes, in the style of the system Notes app: folders and tags, the note
  list, the editor.
- Markdown styled as you type: headings, bold, italic, lists, checkboxes you can
  click, code and links. Notes are stored as plain Markdown text.
- Autosave within a second of your last keystroke. There is no Save command.
- Folders (one level of nesting), tags, pinned notes, sorting by edited date,
  created date or title.
- Images (PNG, JPEG, HEIC) pasted or dragged in, stored encrypted in the
  database.
- Full-text search as you type, with matches highlighted.
- Trash with 30-day recovery.
- Unlock with Touch ID or your Mac password. Locks itself when idle, on sleep,
  on screen lock and on fast user switching.
- Export to Markdown files, import Markdown and text files, and encrypted
  backups you can restore on another Mac.

Offline has no sync, no AI features, no plugins, no collaboration and no iOS
app. Those are deliberate.

## Threat model

Offline protects your notes **at rest** and **while the app is locked**. It
cannot protect what is on screen from a Mac that is already compromised.

| Threat | Protected? | How |
| --- | --- | --- |
| Apple Intelligence / Writing Tools reading note text | Yes | Writing Tools is disabled on every text view and field; no App Intents |
| Siri acting on or reading notes | Yes | No App Intents, no Siri donations, no `NSUserActivity` |
| Spotlight indexing notes | Yes | No Core Spotlight; data is encrypted and kept in a `.noindex` folder |
| Other apps or scripts reading the data file | Yes | Sandboxed container, encrypted database, key in the Keychain |
| Cloud upload (iCloud, cloud backups) | Yes | No network entitlement, no iCloud; the file is ciphertext |
| Stolen or imaged disk | Yes | Encrypted database; the key is never written to disk in plaintext |
| Screenshots and screen recording of the window | Partly | The window is excluded from capture; some capture methods may ignore that |
| Clipboard managers | Partly | Copied text is marked concealed and transient; copying is your choice |
| Someone using your unlocked Mac | Partly | Auto-lock after idle, on sleep and on screen lock |
| Accessibility apps, keyloggers, malware with full control | **No** | Out of scope. Anything that can read your screen or keystrokes can read an unlocked note |

Things worth knowing:

- **VoiceOver and other assistive apps can read notes** while Offline is
  unlocked. That is intentional: assistive technology is your choice. It also
  means any app you have granted Accessibility access can do the same.
- **Exported Markdown files are plain text.** Once you export a note, Offline
  cannot protect it. The app warns you every time.
- **If the Keychain key is lost, the notes are gone.** The key exists only in
  this Mac's Keychain and is never synced. An encrypted backup (File menu) is
  the only recovery path, so make one.
- **Spell checking, autocorrect and text predictions are off** in the editor,
  because they hand text to system language services.
- **Command-clicking a link** opens it in your browser. That is the browser
  using the network, not Offline.
- While a note is open, its text is in the app's memory as ordinary strings.
  Locking closes the database and zeroes the key, but macOS does not let an app
  scrub every copy of text it has displayed.

## How the protections are built

| Requirement | Where |
| --- | --- |
| App Sandbox, no network or iCloud entitlements | `App/Offline.entitlements` |
| Writing Tools, Services, predictions, data detectors off | `Editor/HardenedTextView.swift`, `Editor/HardenedTextField.swift` |
| Every field edits through a hardened field editor | `Lock/HardenedWindow.swift` |
| Window excluded from screen capture | `Lock/HardenedWindow.swift` (`sharingType = .none`) |
| Concealed, transient clipboard | `Editor/ConcealedPasteboard.swift` |
| SQLCipher (AES-256), raw 256-bit key, temp data in memory | `Store/Store+Key.swift`, `Store/Store.swift` |
| Key in the Keychain: user presence, this device only, not synced | `Vault/KeychainKeyStore.swift` |
| Lock closes the database and zeroes the key | `Vault/Vault.swift`, `Vault/SecureBytes.swift` |
| Idle, sleep, screen-lock and user-switch locking | `Lock/LockController.swift`, `Lock/LockPolicy.swift` |
| Encrypted backups (Argon2id + AES-256-GCM) | `Backup/EncryptedBackup.swift` |
| No logging anywhere | enforced by `Scripts/check-privacy.sh` |

Notes live at
`~/Library/Containers/<bundle id>/Data/Library/Application Support/Offline/Data.noindex/offline.db`.

## Building

You need Xcode 16.3 or later.

1. Open `Offline.xcodeproj`.
2. Select the **Offline** target, open **Signing & Capabilities** and choose
   your **Team**. A free personal team works. This step is required: the
   Keychain item that holds the key needs a signed app with a team identifier,
   and an ad-hoc signed build fails at unlock with Keychain error -34018.
3. Change the bundle identifier if `app.offline.notes` is taken for your team.
4. Build and run.

The first build downloads SQLCipher (a checksum-pinned release from
`sqlcipher/SQLCipher.swift`). That is the only download, and it happens in
Xcode, not in the app.

### Tests and checks

```bash
swift test --package-path OfflineKit
```

```bash
Scripts/check-privacy.sh
```

After building, point the script at the app to check the signed entitlements
and linked frameworks as well:

```bash
Scripts/check-privacy.sh path/to/Offline.app
```

The rest of the acceptance checks need a person at a Mac. They are in
[VERIFY.md](VERIFY.md).

## Layout

```
App/                 main.swift and the entitlements: the whole app target
Offline.xcodeproj    thin Xcode project around the package below
OfflineKit/          Swift package with all of the code
  Sources/OfflineCore/   Vault, Store, Backup, Markdown, LockPolicy (no UI)
  Sources/OfflineKit/    Editor, Lock, UI, App (AppKit + SwiftUI)
  Sources/CArgon2/       vendored Argon2 reference implementation
  Tests/                 unit tests
Vendor/GRDB.swift    vendored GRDB, built against SQLCipher
Scripts/             privacy checks and the GRDB vendoring script
```

## Dependencies

Offline has three, and adding another needs a very good reason.

- **[GRDB](https://github.com/groue/GRDB.swift)** (MIT), vendored in
  `Vendor/GRDB.swift`. Upstream GRDB can only use SQLCipher through Swift
  Package Manager if you fork it and edit its manifest, so the repository
  carries an unmodified copy of GRDB's sources with exactly those documented
  manifest edits. `Scripts/vendor-grdb.sh` reproduces it from an upstream tag.
- **[SQLCipher](https://github.com/sqlcipher/SQLCipher.swift)** (BSD-style),
  Zetetic's official Swift package. It ships as a prebuilt, checksum-pinned
  binary framework rather than source.
- **[Argon2 reference implementation](https://github.com/P-H-C/phc-winner-argon2)**
  (CC0 / Apache 2.0), vendored as source in `OfflineKit/Sources/CArgon2`. It
  derives backup keys from passphrases.

## Backup file format

`.offlinebackup` files are documented at the top of
`OfflineKit/Sources/OfflineCore/Backup/EncryptedBackup.swift`. In short: a
42-byte header with the Argon2id parameters and a random salt, followed by
AES-256-GCM records (one manifest, one per image, one end marker). The header
and each record's position are authenticated, so a backup that has been
altered, truncated or reordered is rejected and restoring it changes nothing.

## Contributing

Issues and pull requests are welcome. Three rules are not negotiable:

1. No networking code, analytics, telemetry, auto-update or AI features, not
   even as disabled stubs.
2. No logging of note titles, bodies or search queries, including in debug
   builds. The simplest way to keep that promise is the current one: no
   logging at all.
3. No setting that weakens a protection.

`Scripts/check-privacy.sh` and CI enforce most of this. If you find a way note
content can leave the app, please report it privately to the maintainers
before opening a public issue.

## License

MIT. See [LICENSE](LICENSE). Vendored code keeps its own licenses
(`Vendor/GRDB.swift/LICENSE`, `OfflineKit/Sources/CArgon2/LICENSE`).
