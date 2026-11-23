import AppKit
import Combine
import OfflineCore

/// One row of the note list.
struct NoteRow: Identifiable, Equatable {
    var id: UUID
    var title: String
    var titleMatches: [Range<String.Index>] = []
    var detail: String
    var detailMatches: [Range<String.Index>] = []
    var pinned: Bool
    var date: Date
    var isTrashed: Bool
}

/// An in-window request for a line of text or a passphrase. Shown as an
/// overlay inside the hardened window rather than as a separate sheet.
struct Prompt: Identifiable {
    enum Kind {
        case text
        /// A new passphrase, typed twice.
        case newPassphrase
        case passphrase
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var message: String = ""
    var placeholder: String = ""
    var initialText: String = ""
    var confirmTitle: String = "OK"
    var onSubmit: (String) -> Void
}

/// The app's state and every action the UI can take.
///
/// Note text only passes through here while the vault is unlocked, and
/// `lock()` drops all of it.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        /// First launch: explain the threat model, then create the key.
        case onboarding
        case locked
        case unlocked
        /// The database exists but its Keychain key is gone.
        case keyMissing
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var isAuthenticating = false
    /// A status or error line for the unlock and onboarding screens.
    @Published var notice: String?

    @Published private(set) var folders: [Folder] = []
    @Published private(set) var tags: [TagCount] = []
    /// Notes per folder; a top-level folder's count includes its subfolders.
    @Published private(set) var folderCounts: [UUID: Int] = [:]
    @Published private(set) var allCount = 0
    @Published private(set) var trashCount = 0
    @Published private(set) var scope: NoteScope = .all
    @Published private(set) var rows: [NoteRow] = []
    @Published private(set) var searchText = ""

    @Published private(set) var currentNote: Note?
    @Published var titleDraft = ""
    @Published var tagsDraft = ""
    @Published private(set) var wordCount = 0

    @Published private(set) var searchFocusToken = 0
    @Published private(set) var titleFocusToken = 0
    @Published var prompt: Prompt?
    @Published private(set) var busyMessage: String?
    @Published private(set) var lockStatus = ""

    let settings: SettingsStore
    let editor = EditorController()
    let lockController = LockController()
    let vault: Vault

    var store: Store? { vault.store }
    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(vault: Vault, settings: SettingsStore) {
        self.vault = vault
        self.settings = settings

        editor.onChange = { [weak self] in self?.editorDidChange() }
        editor.storeImage = { [weak self] data, mimeType in
            guard let self, let store = self.store, let note = self.currentNote else { return nil }
            return try? store.addAttachment(noteID: note.id, mimeType: mimeType, data: data)
        }
        editor.loadImage = { [weak self] id in
            (try? self?.store?.attachment(id: id))?.data
        }
        editor.setTypography(settings.typography)

        lockController.policy = settings.lockPolicy
        lockController.onLock = { [weak self] in self?.lock() }
        lockController.onTick = { [weak self] in self?.refreshLockStatus() }

        settings.$typography
            .sink { [weak self] value in self?.editor.setTypography(value) }
            .store(in: &cancellables)
        settings.$autoLockMinutes
            .sink { [weak self] minutes in
                self?.lockController.policy = LockPolicy(timeoutMinutes: minutes)
                self?.refreshLockStatus()
            }
            .store(in: &cancellables)
        settings.$sort
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadNotes() }
            .store(in: &cancellables)
        settings.$excludeFromTimeMachine
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyBackupExclusion() }
            .store(in: &cancellables)
    }

    var isUnlocked: Bool { phase == .unlocked }
    var isTrashSelected: Bool { scope == .trash }

    // MARK: - Launch, unlock, lock

    func start() {
        lockController.start()
        refreshPhase()
        if phase == .locked {
            unlock()
        }
    }

    private func refreshPhase() {
        do {
            switch try vault.status() {
            case .needsSetup: phase = .onboarding
            case .ready: phase = .locked
            case .keyMissing: phase = .keyMissing
            }
        } catch {
            phase = .locked
            notice = Self.message(for: error)
        }
    }

    /// First launch: asks for Touch ID or the Mac password, then creates the
    /// key and the encrypted database.
    func createVault() {
        authenticate(reason: "create the key that encrypts your notes") { vault, reason in
            try vault.create(reason: reason)
        }
    }

    func unlock() {
        guard phase == .locked else { return }
        authenticate(reason: "unlock your notes") { vault, reason in
            try vault.unlock(reason: reason)
        }
    }

    private func authenticate(
        reason: String,
        _ work: @escaping @Sendable (Vault, String) throws -> Store
    ) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        notice = nil
        let vault = self.vault
        Task {
            // The Keychain call blocks while the system prompt is up, so it
            // runs off the main thread.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try work(vault, reason) }
            }.value
            self.isAuthenticating = false
            switch result {
            case .success:
                self.didUnlock()
            case .failure(let error):
                if (error as? VaultError) != .userCancelled {
                    self.notice = Self.message(for: error)
                }
                self.refreshPhase()
            }
        }
    }

    private func didUnlock() {
        guard let store else { return }
        _ = try? store.purgeExpiredTrash()
        _ = try? store.pruneOrphanAttachments()
        applyBackupExclusion()
        lockController.noteActivity()
        phase = .unlocked
        scope = .all
        searchText = ""
        reloadSidebar()
        reloadNotes()
        if let first = rows.first {
            select(noteID: first.id)
        }
        refreshLockStatus()
    }

    /// Saves pending edits, removes every trace of note content from the UI,
    /// closes the database and zeroes the key.
    func lock() {
        guard phase == .unlocked else { return }
        saveNow()
        saveTask?.cancel()
        saveTask = nil

        editor.clear()
        currentNote = nil
        titleDraft = ""
        tagsDraft = ""
        wordCount = 0
        rows = []
        folders = []
        tags = []
        folderCounts = [:]
        allCount = 0
        trashCount = 0
        searchText = ""
        scope = .all
        prompt = nil
        busyMessage = nil
        notice = nil
        ConcealedPasteboard.clearIfOwned()

        vault.lockNow()
        phase = .locked
    }

    /// For a database whose key is gone: keeps the old encrypted file aside
    /// and starts over.
    func startFreshAfterKeyLoss() {
        do {
            try vault.setAsideOrphanedData()
            notice = nil
            refreshPhase()
        } catch {
            notice = Self.message(for: error)
        }
    }

    private func refreshLockStatus() {
        let text = phase == .unlocked ? lockController.statusText : ""
        if text != lockStatus { lockStatus = text }
    }

    private func applyBackupExclusion() {
        var url = vault.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = settings.excludeFromTimeMachine
        try? url.setResourceValues(values)
    }

    // MARK: - Loading lists

    func reloadSidebar() {
        guard let store else { return }
        perform {
            folders = try store.folders()
            tags = try store.tags()
            var counts = try store.noteCountsByFolder()
            for folder in folders {
                if let parentID = folder.parentID, let own = counts[folder.id] {
                    counts[parentID, default: 0] += own
                }
            }
            folderCounts = counts
            allCount = try store.noteCount(in: .all)
            trashCount = try store.noteCount(in: .trash)
        }
        // A deleted folder or tag cannot stay selected.
        switch scope {
        case .folder(let id) where !folders.contains(where: { $0.id == id }):
            scope = .all
        case .tag(let id) where !tags.contains(where: { $0.id == id }):
            scope = .all
        default:
            break
        }
    }

    func reloadNotes() {
        guard let store else { return }
        perform {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty || scope == .trash {
                rows = try store.notes(in: scope, sortedBy: settings.sort).map { summary in
                    NoteRow(
                        id: summary.id,
                        title: summary.title,
                        detail: Self.previewLine(summary.preview),
                        pinned: summary.pinned,
                        date: scope == .trash
                            ? (summary.deletedAt ?? summary.updatedAt)
                            : (settings.sort == .created ? summary.createdAt : summary.updatedAt),
                        isTrashed: summary.deletedAt != nil
                    )
                }
            } else {
                rows = try store.search(query, in: scope).map { hit in
                    let title = SearchMarkup.parse(hit.markedTitle)
                    let snippet = SearchMarkup.parse(hit.markedSnippet.replacingOccurrences(of: "\n", with: " "))
                    return NoteRow(
                        id: hit.note.id,
                        title: title.text,
                        titleMatches: title.matches,
                        detail: snippet.text,
                        detailMatches: snippet.matches,
                        pinned: hit.note.pinned,
                        date: hit.note.updatedAt,
                        isTrashed: false
                    )
                }
            }
        }
    }

    private static func previewLine(_ preview: String) -> String {
        let cleaned = AttachmentReference.findAll(in: preview).reversed().reduce(into: NSMutableString(string: preview)) {
            $0.replaceCharacters(in: $1.range, with: "[image]")
        } as String
        return cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// The name of what the list is showing, for its header.
    var scopeTitle: String {
        switch scope {
        case .all: return "All Notes"
        case .trash: return "Trash"
        case .folder(let id): return folders.first { $0.id == id }?.name ?? "Folder"
        case .tag(let id): return tags.first { $0.id == id }.map { "#" + $0.tag.name } ?? "Tag"
        }
    }

    var isSearching: Bool { !searchTerms.isEmpty }

    var searchTerms: [String] {
        scope == .trash ? [] : SearchQuery.terms(in: searchText)
    }

    // MARK: - Navigation

    func setScope(_ newScope: NoteScope) {
        guard newScope != scope else { return }
        saveNow()
        scope = newScope
        reloadNotes()
        select(noteID: rows.first?.id)
    }

    func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        reloadNotes()
        editor.setHighlightTerms(searchTerms)
        // Keep the open note if it still matches; otherwise show the best hit.
        if let current = currentNote, rows.contains(where: { $0.id == current.id }) {
            return
        }
        if !searchTerms.isEmpty {
            select(noteID: rows.first?.id)
        }
    }

    func focusSearch() {
        guard phase == .unlocked else { return }
        searchFocusToken += 1
    }

    var selectedNoteID: UUID? { currentNote?.id }

    func select(noteID: UUID?) {
        guard noteID != currentNote?.id else { return }
        saveNow()
        guard let noteID, let store, let note = try? store.note(id: noteID) else {
            currentNote = nil
            titleDraft = ""
            tagsDraft = ""
            wordCount = 0
            editor.clear()
            return
        }
        currentNote = note
        titleDraft = note.title
        tagsDraft = ((try? store.tags(forNote: note.id)) ?? []).map(\.name).joined(separator: ", ")
        editor.setHighlightTerms(searchTerms)
        editor.load(markdown: note.body, editable: note.deletedAt == nil)
        wordCount = MarkdownEditing.wordCount(editor.visibleText)
    }

    // MARK: - Editing and autosave

    private func editorDidChange() {
        wordCount = MarkdownEditing.wordCount(editor.visibleText)
        scheduleSave()
    }

    func titleDidChange() {
        scheduleSave()
    }

    /// Saves shortly after the last change (well under a second), so there is
    /// no Save command.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the open note if it changed.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let store, let note = currentNote, note.deletedAt == nil else { return }
        let body = editor.markdown
        let title = titleDraft.trimmingCharacters(in: .newlines)
        guard title != note.title || body != note.body else { return }
        perform {
            if try store.updateNote(id: note.id, title: title, body: body) {
                currentNote = try store.note(id: note.id)
                reloadNotes()
            }
        }
    }

    func commitTags() {
        guard let store, let note = currentNote, note.deletedAt == nil else { return }
        let names = TagName.parse(tagsDraft)
        perform {
            let existing = try store.tags(forNote: note.id).map(\.name)
            if existing.map({ $0.lowercased() }).sorted() != names.map({ $0.lowercased() }).sorted() {
                try store.setTags(names, forNote: note.id)
                reloadSidebar()
            }
            tagsDraft = try store.tags(forNote: note.id).map(\.name).joined(separator: ", ")
        }
    }

    // MARK: - Notes

    func newNote() {
        guard let store, phase == .unlocked else { return }
        saveNow()
        if scope == .trash { scope = .all }
        var folderID: UUID?
        var tagToApply: String?
        switch scope {
        case .folder(let id): folderID = id
        case .tag(let id): tagToApply = tags.first { $0.id == id }?.tag.name
        default: break
        }
        if !searchText.isEmpty {
            searchText = ""
            editor.setHighlightTerms([])
        }
        perform {
            let note = try store.createNote(folderID: folderID)
            if let tagToApply {
                try store.setTags([tagToApply], forNote: note.id)
            }
            reloadSidebar()
            reloadNotes()
            select(noteID: note.id)
            titleFocusToken += 1
        }
    }

    /// Moves a note to the Trash, or removes it for good if it is already
    /// there (after confirmation).
    func deleteNote(id: UUID?) {
        guard let store, let id, let row = rows.first(where: { $0.id == id }) ?? currentRow(id) else { return }
        if row.isTrashed {
            guard confirm(
                "Delete this note permanently?",
                detail: "It cannot be restored.",
                button: "Delete"
            ) else { return }
            if currentNote?.id == id { discardCurrentNote() }
            perform { try store.deleteNotePermanently(id: id) }
        } else {
            if currentNote?.id == id {
                saveNow()
                discardCurrentNote()
            }
            perform { try store.trashNote(id: id) }
        }
        reloadSidebar()
        reloadNotes()
        if currentNote == nil { select(noteID: rows.first?.id) }
    }

    private func currentRow(_ id: UUID) -> NoteRow? {
        guard let note = currentNote, note.id == id else { return nil }
        return NoteRow(
            id: id, title: note.title, detail: "", pinned: note.pinned,
            date: note.updatedAt, isTrashed: note.deletedAt != nil
        )
    }

    private func discardCurrentNote() {
        saveTask?.cancel()
        saveTask = nil
        currentNote = nil
        titleDraft = ""
        tagsDraft = ""
        wordCount = 0
        editor.clear()
    }

    func restoreNote(id: UUID) {
        guard let store else { return }
        perform { try store.restoreNote(id: id) }
        if currentNote?.id == id { discardCurrentNote() }
        reloadSidebar()
        reloadNotes()
        select(noteID: rows.first?.id)
    }

    func emptyTrash() {
        guard let store, trashCount > 0 else { return }
        guard confirm(
            "Empty the Trash?",
            detail: "All notes in the Trash will be deleted permanently.",
            button: "Empty Trash"
        ) else { return }
        if currentNote?.deletedAt != nil { discardCurrentNote() }
        perform { try store.emptyTrash() }
        reloadSidebar()
        reloadNotes()
    }

    func duplicateNote(id: UUID) {
        guard let store else { return }
        saveNow()
        perform {
            let copy = try store.duplicateNote(id: id)
            reloadSidebar()
            reloadNotes()
            select(noteID: copy.id)
        }
    }

    func togglePin(id: UUID) {
        guard let store, let row = rows.first(where: { $0.id == id }) else { return }
        perform {
            try store.setPinned(!row.pinned, noteID: id)
            if currentNote?.id == id { currentNote?.pinned = !row.pinned }
            reloadNotes()
        }
    }

    func moveNote(id: UUID, toFolder folderID: UUID?) {
        guard let store else { return }
        perform {
            try store.moveNote(id: id, toFolder: folderID)
            if currentNote?.id == id { currentNote?.folderID = folderID }
            reloadSidebar()
            reloadNotes()
        }
    }

    /// Puts keyboard focus in the title field ("Rename").
    func renameCurrentNote() {
        guard currentNote?.deletedAt == nil, currentNote != nil else { return }
        titleFocusToken += 1
    }

    // MARK: - Folders

    func newFolder(parentID: UUID? = nil) {
        guard let store, phase == .unlocked else { return }
        prompt = Prompt(
            kind: .text,
            title: parentID == nil ? "New Folder" : "New Subfolder",
            placeholder: "Folder name",
            confirmTitle: "Create"
        ) { [weak self] name in
            guard let self else { return }
            self.perform {
                let folder = try store.createFolder(name: name, parentID: parentID)
                self.reloadSidebar()
                self.setScope(.folder(folder.id))
            }
        }
    }

    func renameFolder(_ folder: Folder) {
        guard let store else { return }
        prompt = Prompt(
            kind: .text,
            title: "Rename Folder",
            placeholder: "Folder name",
            initialText: folder.name,
            confirmTitle: "Rename"
        ) { [weak self] name in
            guard let self else { return }
            self.perform {
                try store.renameFolder(id: folder.id, to: name)
                self.reloadSidebar()
            }
        }
    }

    func deleteFolder(_ folder: Folder) {
        guard let store else { return }
        guard confirm(
            "Delete this folder?",
            detail: "Its notes are kept and move to All Notes. Any subfolders are removed too.",
            button: "Delete Folder"
        ) else { return }
        perform { try store.deleteFolder(id: folder.id) }
        reloadSidebar()
        reloadNotes()
    }

    // MARK: - Helpers

    func setBusy(_ message: String?) {
        busyMessage = message
    }

    /// Runs store work and reports any failure in an alert.
    func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            showError(error)
        }
    }

    func confirm(_ message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runHardened() == .alertFirstButtonReturn
    }

    func showMessage(_ message: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runHardened()
    }

    func showError(_ error: Error) {
        showMessage("Something went wrong", detail: Self.message(for: error))
    }

    /// A plain description of an error. Never includes note content.
    static func message(for error: Error) -> String {
        switch error {
        case let error as VaultError:
            switch error {
            case .locked: return "Offline is locked."
            case .userCancelled: return "Unlock was cancelled."
            case .authenticationFailed:
                return "Touch ID or your Mac password could not be verified. A Mac login password is required."
            case .keyNotFound, .keyMissingForExistingData:
                return "The encryption key is missing from the Keychain."
            case .keyAlreadyExists, .vaultAlreadyExists:
                return "A key already exists. Unlock to continue."
            case .malformedKey: return "The stored key is damaged."
            case .keychain(let status):
                if status == -34018 {
                    return "The Keychain refused access (-34018). The app must be signed with a development team to use the Keychain."
                }
                return "The Keychain returned error \(status)."
            }
        case let error as StoreError:
            switch error {
            case .wrongKeyOrCorrupt: return "The notes database could not be opened with this key."
            case .encryptionUnavailable:
                return "This build has no database encryption, so Offline will not store anything."
            case .notFound: return "That item no longer exists."
            case .nestingTooDeep: return "Folders can only be nested one level deep."
            case .invalidName: return "Please enter a name."
            case .databaseTooNew: return "The notes database was made by a newer version of Offline."
            }
        case let error as EncryptedBackup.Failure:
            switch error {
            case .passphraseTooShort:
                return "The passphrase needs at least \(EncryptedBackup.minimumPassphraseLength) characters."
            case .unrecognizedFile: return "That file is not an Offline backup this version can read."
            case .wrongPassphraseOrDamaged:
                return "The passphrase is wrong or the backup file is damaged. Nothing was changed."
            case .incomplete: return "The backup file is incomplete or damaged. Nothing was changed."
            }
        case is Argon2id.Failure:
            return "The passphrase could not be processed."
        default:
            let nsError = error as NSError
            return "Error \(nsError.code) (\(nsError.domain))."
        }
    }
}
