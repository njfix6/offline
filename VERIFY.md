# Verifying a build

A build ships only when every check below passes. The first group is
automated; the second needs a person at a real Mac. Use a signed build (see
"Building" in the README) and a note containing a unique word you would never
type otherwise. The examples use `xylophonequokka`.

## Automated

| Check | How it is verified |
| --- | --- |
| Vault: key is created once, loaded on unlock, zeroed on lock | `VaultTests`, `SecureBytesTests` |
| Store migrations create the schema and refuse a newer database | `StoreTests` |
| FTS5 index follows inserts, updates and deletes | `SearchTests` |
| Database file is unrecognisable and holds no plaintext, including the WAL | `EncryptionAtRestTests` (macOS only: needs SQLCipher) |
| A wrong key cannot open the database | `EncryptionAtRestTests` (macOS only) |
| Backup round-trips into a vault with a different key; fails with a wrong passphrase; tampered or truncated files change nothing | `EncryptedBackupTests` |
| Backup file holds no plaintext | `EncryptedBackupTests` |
| Argon2id matches the reference test vector | `Argon2Tests` |
| Auto-lock time is clamped to 1–60 minutes and cannot be disabled | `LockPolicyTests` |
| Sandbox on; no network, iCloud or other entitlements | `Scripts/check-privacy.sh` |
| No networking, iCloud, Spotlight, Siri, AI, logging, sharing or Services-provider APIs in the source | `Scripts/check-privacy.sh` |
| Every text view derives from `HardenedTextView`; no SwiftUI text inputs; no windows outside `HardenedWindow` | `Scripts/check-privacy.sh` |
| Signed app: entitlements, linked frameworks, Hardened Runtime | `Scripts/check-privacy.sh path/to/Offline.app` |

Run them:

```bash
swift test --package-path OfflineKit
```

```bash
Scripts/check-privacy.sh path/to/Offline.app
```

## Manual checklist

Tick each box on a real Mac, and note the macOS version and the date.

### Entitlements and network

- [ ] `codesign -d --entitlements - Offline.app` shows `com.apple.security.app-sandbox` and no `network` or `icloud` entitlement.
- [ ] With Little Snitch or LuLu running, a full session (create a note, search, export, back up, lock, unlock) makes **zero** network connections from Offline.

### Encryption at rest

Run these in Terminal after a session, with the app locked. Replace the bundle
identifier if you changed it.

```bash
cd ~/Library/Containers/app.offline.notes/Data
```

- [ ] `file "Library/Application Support/Offline/Data.noindex/offline.db"` reports `data`, not `SQLite`.
- [ ] `strings "Library/Application Support/Offline/Data.noindex/offline.db" | grep -i xylophonequokka` prints nothing.
- [ ] `grep -r -i xylophonequokka .` over the whole container prints nothing. (Run it while the app is unlocked too, so the `-wal` file is covered.)
- [ ] `ls Library/Caches tmp` shows no file containing note text, and there is no Quick Look thumbnail of a note.

### Keychain and unlock

- [ ] First launch shows the threat-model screen, then asks for Touch ID or the Mac password before creating the key.
- [ ] Every unlock asks for Touch ID or the Mac password. Cancelling leaves the app locked.
- [ ] In Keychain Access, the "Offline data key" item is not in the iCloud keychain.
- [ ] `security find-generic-password -s app.offline.notes.datakey -w` from Terminal does not print the key.

### Apple Intelligence, Siri, Spotlight

- [ ] Select text in the editor and Control-click: the menu has only Cut, Copy, Paste and Select All. No Writing Tools, Services, Look Up, Translate, Search With or Share.
- [ ] Do the same in the title field, the tags field and the search field.
- [ ] The Edit menu has no Writing Tools, AutoFill, Start Dictation or Emoji & Symbols item.
- [ ] With Apple Intelligence enabled, hovering over selected text shows no Writing Tools affordance.
- [ ] Asking Siri about your notes ("what's in my Offline notes", the unique word) returns nothing from the app, and Offline does not appear under Siri & Spotlight suggestions or in Shortcuts.
- [ ] After an hour of use, `mdfind xylophonequokka` prints nothing.

### Screen and clipboard

- [ ] A screenshot (⌘⇧3), a window screenshot (⌘⇧4, Space) and a QuickTime screen recording show the Offline window blank or absent. **Write down any capture method that still shows it** (for example a specific screen-sharing app) so the README can list it.
- [ ] Sharing your screen in a video call does not show the Offline window.
- [ ] The Settings window is excluded from capture too.
- [ ] Copy text in Offline, then check a clipboard manager such as Maccy: the item was skipped.
- [ ] Copy text in Offline, lock the app, then paste elsewhere: the clipboard is empty.

### Locking

- [ ] With auto-lock set to 1 minute, the app locks after a minute without input to Offline.
- [ ] The lock icon's tooltip reads "Locks in N min".
- [ ] The app locks on sleep (close the lid), on screen lock (⌃⌘Q), when the screen saver starts and on fast user switching.
- [ ] ⌘L and the menu-bar lock icon both lock immediately.
- [ ] While locked, the window and Mission Control show only the lock screen: no note titles or text.
- [ ] Closing the window locks the app.

### Logs

- [ ] `log stream --predicate 'subsystem contains "offline" OR process == "Offline"'` during a session shows no note titles, text or search terms.
- [ ] After a forced crash (`kill -SEGV`), the crash report in Console contains no note text.

### Backup, import, export

- [ ] Export warns that the files are unencrypted before the folder picker appears.
- [ ] An encrypted backup restores in a fresh user account (or on a second Mac) with the passphrase.
- [ ] Restoring with a wrong passphrase fails and leaves the existing notes untouched.
- [ ] `strings backup.offlinebackup | grep -i xylophonequokka` prints nothing.

### Accessibility

- [ ] VoiceOver reads the sidebar, the note list, the title and the note text, and every icon button has a spoken label.
- [ ] The whole app can be used from the keyboard: ⌘N, ⌘F, ⌘L, ⌘⌫, ⌘⇧E, Tab between panes, arrow keys in the lists.
- [ ] View › Bigger Text and Smaller Text scale the editor.
