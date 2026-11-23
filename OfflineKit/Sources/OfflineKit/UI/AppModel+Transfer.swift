import AppKit
import OfflineCore
import UniformTypeIdentifiers

/// Export, import, encrypted backup and restore.
///
/// The open and save panels are the system's sandbox panels: Offline only
/// gets access to the exact files and folders the user picks.
extension AppModel {
    // MARK: - Markdown export

    func exportCurrentNote() {
        guard let note = currentNote else {
            exportAllNotes()
            return
        }
        saveNow()
        export(title: "Export This Note") { store, directory in
            try MarkdownExport.exportNote(id: note.id, from: store, to: directory)
        }
    }

    func exportAllNotes() {
        saveNow()
        export(title: "Export All Notes") { store, directory in
            try MarkdownExport.exportAll(from: store, to: directory)
        }
    }

    private func export(
        title: String,
        _ work: @escaping @Sendable (Store, URL) throws -> MarkdownExport.Report
    ) {
        guard let store, phase == .unlocked else { return }

        let warning = NSAlert()
        warning.alertStyle = .critical
        warning.messageText = "Exported files are not encrypted"
        warning.informativeText = """
            The Markdown files and images you export are plain, readable files. Anything on this Mac \
            can read them: other apps, Spotlight, backups, cloud sync folders and AI assistants.

            Offline cannot protect a note once it has been exported.
            """
        warning.addButton(withTitle: "Cancel")
        warning.addButton(withTitle: "Export Unencrypted…")
        guard warning.runHardened() == .alertSecondButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Choose a folder for the unencrypted Markdown files."
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        runInBackground("Exporting…") {
            try work(store, directory)
        } completion: { [weak self] report in
            self?.showMessage(
                "Export finished",
                detail: "\(report.noteCount) note(s) and \(report.imageCount) image(s) were written as plain files."
            )
        }
    }

    // MARK: - Markdown import

    func importFiles() {
        guard let store, phase == .unlocked else { return }
        saveNow()

        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.message = "Choose Markdown or plain-text files, or folders of them."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.plainText, .folder]
        for pathExtension in ["md", "markdown", "mdown", "txt", "text"] {
            if let type = UTType(filenameExtension: pathExtension) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls

        var folderID: UUID?
        if case .folder(let id) = scope { folderID = id }

        runInBackground("Importing…") {
            try MarkdownImport.importItems(urls, into: store, folderID: folderID)
        } completion: { [weak self] report in
            guard let self else { return }
            self.reloadSidebar()
            self.reloadNotes()
            var detail = "\(report.noteCount) note(s) and \(report.imageCount) image(s) were imported."
            if report.skippedCount > 0 {
                detail += " \(report.skippedCount) file(s) were skipped because they are not text."
            }
            detail += "\n\nThe original files were not changed and are still unencrypted where they were."
            self.showMessage("Import finished", detail: detail)
        }
    }

    // MARK: - Encrypted backup

    func createBackup() {
        guard store != nil, phase == .unlocked else { return }
        saveNow()
        prompt = Prompt(
            kind: .newPassphrase,
            title: "Create Encrypted Backup",
            message: """
                Choose a passphrase of at least \(EncryptedBackup.minimumPassphraseLength) characters. \
                It is the only way to open this backup: there is no reset, and it is not stored anywhere.
                """,
            placeholder: "Passphrase",
            confirmTitle: "Continue"
        ) { [weak self] passphrase in
            self?.writeBackup(passphrase: passphrase)
        }
    }

    private func writeBackup(passphrase: String) {
        guard let store else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let panel = NSSavePanel()
        panel.title = "Save Encrypted Backup"
        panel.nameFieldStringValue = "Offline \(formatter.string(from: Date())).\(EncryptedBackup.fileExtension)"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: EncryptedBackup.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        runInBackground("Encrypting backup…") {
            try EncryptedBackup.write(store: store, to: url, passphrase: passphrase)
        } completion: { [weak self] summary in
            self?.showMessage(
                "Backup saved",
                detail: """
                    \(summary.noteCount) note(s) and \(summary.attachmentCount) image(s) were encrypted. \
                    Keep the passphrase somewhere safe: without it the backup cannot be opened.
                    """
            )
        }
    }

    func restoreBackup() {
        guard store != nil, phase == .unlocked else { return }
        saveNow()
        guard confirm(
            "Replace all notes with a backup?",
            detail: """
                Restoring replaces everything currently in Offline, including the Trash, with the \
                contents of the backup. This cannot be undone. Consider creating a backup of the \
                current notes first.
                """,
            button: "Choose Backup…"
        ) else { return }

        let panel = NSOpenPanel()
        panel.title = "Restore from Encrypted Backup"
        panel.prompt = "Restore"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: EncryptedBackup.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        prompt = Prompt(
            kind: .passphrase,
            title: "Backup Passphrase",
            message: "Enter the passphrase this backup was created with.",
            placeholder: "Passphrase",
            confirmTitle: "Restore"
        ) { [weak self] passphrase in
            self?.readBackup(from: url, passphrase: passphrase)
        }
    }

    private func readBackup(from url: URL, passphrase: String) {
        guard let store else { return }
        // Nothing from the old vault may linger in the editor.
        select(noteID: nil)
        runInBackground("Decrypting backup…") {
            try EncryptedBackup.restore(from: url, passphrase: passphrase, into: store)
        } completion: { [weak self] summary in
            guard let self else { return }
            self.setScope(.all)
            self.reloadSidebar()
            self.reloadNotes()
            self.select(noteID: self.rows.first?.id)
            self.showMessage(
                "Backup restored",
                detail: "\(summary.noteCount) note(s) and \(summary.attachmentCount) image(s) were restored."
            )
        } failure: { [weak self] in
            self?.reloadSidebar()
            self?.reloadNotes()
        }
    }

    // MARK: - Background work

    /// Runs slow work off the main thread behind a "busy" overlay.
    private func runInBackground<T: Sendable>(
        _ message: String,
        _ work: @escaping @Sendable () throws -> T,
        completion: @escaping @MainActor (T) -> Void,
        failure: @escaping @MainActor () -> Void = {}
    ) {
        setBusy(message)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try work() }
            }.value
            // If the app locked while this ran, there is nothing to report to.
            guard self.phase == .unlocked else { return }
            self.setBusy(nil)
            self.lockController.noteActivity()
            switch result {
            case .success(let value):
                completion(value)
            case .failure(let error):
                failure()
                self.showError(error)
            }
        }
    }
}
