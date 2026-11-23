import OfflineCore
import SwiftUI

/// Layout constants shared by the three panes.
enum Chrome {
    /// Height of the bar at the top of each pane. Together the three bars
    /// stand in for a window toolbar.
    static let barHeight: CGFloat = 52
    /// The warm yellow used for folders and the selected note, in the spirit
    /// of the system Notes app.
    static let accent = Color(nsColor: .systemYellow)
}

/// The unlocked app, laid out like the system Notes app but simpler: folders
/// and tags on the left, the note list in the middle, the note on the right.
struct MainView: View {
    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 300)
            NoteListView()
                .frame(minWidth: 240, idealWidth: 290, maxWidth: 420)
            EditorPane()
                .frame(minWidth: 400, maxWidth: .infinity)
                .layoutPriority(1)
        }
        .ignoresSafeArea(.all, edges: .top)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    private var selection: Binding<NoteScope?> {
        Binding(
            get: { model.scope },
            set: { if let scope = $0 { model.setScope(scope) } }
        )
    }

    private var topLevelFolders: [Folder] {
        model.folders.filter { $0.parentID == nil }
    }

    private func children(of folder: Folder) -> [Folder] {
        model.folders.filter { $0.parentID == folder.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The window's close/minimise/zoom buttons sit over the left of
            // this bar.
            HStack {
                Spacer()
                Button {
                    model.newFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("New Folder")
                .accessibilityLabel("New Folder")
            }
            .padding(.horizontal, 14)
            .frame(height: Chrome.barHeight)

            List(selection: selection) {
                row("All Notes", symbol: "tray.full", count: model.allCount)
                    .tag(NoteScope.all)

                if !model.folders.isEmpty {
                    Section("Folders") {
                        ForEach(topLevelFolders) { folder in
                            folderRow(folder, isChild: false)
                            ForEach(children(of: folder)) { child in
                                folderRow(child, isChild: true)
                            }
                        }
                    }
                }

                if !model.tags.isEmpty {
                    Section("Tags") {
                        ForEach(model.tags) { item in
                            row(item.tag.name, symbol: "number", count: item.noteCount)
                                .tag(NoteScope.tag(item.tag.id))
                        }
                    }
                }

                Section {
                    row("Trash", symbol: "trash", count: model.trashCount)
                        .tag(NoteScope.trash)
                        .contextMenu {
                            Button("Empty Trash") { model.emptyTrash() }
                                .disabled(model.trashCount == 0)
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Folders and tags")
        }
        .background(.regularMaterial)
    }

    private func row(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Chrome.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) notes")
    }

    private func folderRow(_ folder: Folder, isChild: Bool) -> some View {
        row(folder.name, symbol: "folder", count: model.folderCounts[folder.id] ?? 0)
            .padding(.leading, isChild ? 18 : 0)
            .tag(NoteScope.folder(folder.id))
            .contextMenu {
                if !isChild {
                    Button("New Subfolder") { model.newFolder(parentID: folder.id) }
                }
                Button("Rename…") { model.renameFolder(folder) }
                Divider()
                Button("Delete Folder…", role: .destructive) { model.deleteFolder(folder) }
            }
    }
}

// MARK: - Note list

struct NoteListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedNoteID },
            set: { model.select(noteID: $0) }
        )
    }

    private struct NoteSection: Identifiable {
        var title: String
        var items: [NoteRow]
        var id: String { title }
    }

    /// Rows grouped under headings: pinned notes first, then by age. Search
    /// results and the Trash are shown as one flat list.
    private var sections: [NoteSection] {
        if model.isSearching {
            return [NoteSection(title: "Results", items: model.rows)]
        }
        if model.isTrashSelected {
            return [NoteSection(title: "", items: model.rows)]
        }
        let pinned = model.rows.filter(\.pinned)
        let others = model.rows.filter { !$0.pinned }
        var result: [NoteSection] = []
        if !pinned.isEmpty { result.append(NoteSection(title: "Pinned", items: pinned)) }
        if settings.sort == .title {
            if !others.isEmpty {
                result.append(NoteSection(title: pinned.isEmpty ? "" : "Notes", items: others))
            }
        } else {
            let now = Date()
            result += DateSection.group(others) { DateSection.title(for: $0.date, now: now) }
                .map { NoteSection(title: $0.title, items: $0.items) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.scopeTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(model.rows.count == 1 ? "1 note" : "\(model.rows.count) notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)

                Menu {
                    Picker("Sort By", selection: $settings.sort) {
                        Text("Date Edited").tag(NoteSort.modified)
                        Text("Date Created").tag(NoteSort.created)
                        Text("Title").tag(NoteSort.title)
                    }
                    .pickerStyle(.inline)
                    if model.isTrashSelected {
                        Divider()
                        Button("Empty Trash") { model.emptyTrash() }
                            .disabled(model.trashCount == 0)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort and list options")
                .accessibilityLabel("Sort and list options")

                Button {
                    model.newNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("New Note (⌘N)")
                .accessibilityLabel("New Note")
            }
            .padding(.horizontal, 16)
            .frame(height: Chrome.barHeight)

            Divider()

            if model.rows.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { row in
                                NoteRowView(row: row, isSelected: row.id == model.selectedNoteID)
                                    .tag(row.id)
                                    .listRowSeparator(.visible)
                                    .contextMenu { rowMenu(row) }
                            }
                        } header: {
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Notes")
            }

            if model.isTrashSelected {
                Divider()
                Text("Notes in the Trash are removed after \(Store.trashRetentionDays) days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyMessage: String {
        if model.isTrashSelected { return "The Trash is empty" }
        return model.isSearching ? "No results" : "No notes"
    }

    @ViewBuilder
    private func rowMenu(_ row: NoteRow) -> some View {
        if row.isTrashed {
            Button("Restore") { model.restoreNote(id: row.id) }
            Divider()
            Button("Delete Permanently…", role: .destructive) { model.deleteNote(id: row.id) }
        } else {
            Button(row.pinned ? "Unpin" : "Pin to Top") { model.togglePin(id: row.id) }
            Button("Duplicate") { model.duplicateNote(id: row.id) }
            Menu("Move to") {
                Button("No Folder") { model.moveNote(id: row.id, toFolder: nil) }
                Divider()
                ForEach(model.folders.filter { $0.parentID == nil }) { folder in
                    Button(folder.name) { model.moveNote(id: row.id, toFolder: folder.id) }
                    ForEach(model.folders.filter { $0.parentID == folder.id }) { child in
                        Button("    " + child.name) { model.moveNote(id: row.id, toFolder: child.id) }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteNote(id: row.id) }
        }
    }
}

/// A note in the list: bold title, then the date and the start of the text.
struct NoteRowView: View {
    let row: NoteRow
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if row.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Chrome.accent)
                        .accessibilityLabel("Pinned")
                }
                Text(highlighted(row.title.isEmpty ? "New Note" : row.title, row.title.isEmpty ? [] : row.titleMatches))
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Self.shortDate(row.date))
                    .foregroundStyle(.primary.opacity(0.85))
                    .layoutPriority(1)
                Text(highlighted(row.detail.isEmpty ? "No additional text" : row.detail, row.detail.isEmpty ? [] : row.detailMatches))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .padding(.vertical, 5)
        .padding(.leading, 8)
        .accessibilityElement(children: .combine)
    }

    /// Time for today, "Yesterday", the weekday within a week, otherwise a
    /// short date.
    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 0 {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else if days == 1 {
            return "Yesterday"
        } else if days < 7 {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    /// Tints the parts of `text` that matched the search.
    private func highlighted(_ text: String, _ matches: [Range<String.Index>]) -> AttributedString {
        var result = AttributedString(text)
        for match in matches {
            guard let lower = AttributedString.Index(match.lowerBound, within: result),
                  let upper = AttributedString.Index(match.upperBound, within: result)
            else { continue }
            result[lower..<upper].backgroundColor = Chrome.accent.opacity(0.45)
        }
        return result
    }
}

// MARK: - Editor

struct EditorPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore

    private var note: Note? { model.currentNote }
    private var isTrashed: Bool { note?.deletedAt != nil }

    private var searchText: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { model.setSearchText($0) }
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if note != nil {
                noteHeader
            }
            ZStack {
                // The editor view stays alive so it keeps its text view; the
                // placeholder simply covers it when no note is open.
                NoteEditorView(controller: model.editor)
                if note == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.system(size: 38))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text("No Note Selected")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Button("New Note") { model.newNote() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Note actions on the left, lock and search on the right.
    private var topBar: some View {
        HStack(spacing: 14) {
            if let note, !isTrashed {
                Button {
                    model.togglePin(id: note.id)
                } label: {
                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                }
                .help(note.pinned ? "Unpin" : "Pin to Top")
                .accessibilityLabel(note.pinned ? "Unpin note" : "Pin note to top")

                Button {
                    model.deleteNote(id: note.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete (⌘⌫)")
                .accessibilityLabel("Delete note")
            } else if let note {
                Button("Restore") { model.restoreNote(id: note.id) }
                    .buttonStyle(.bordered)
                Button("Delete Permanently…") { model.deleteNote(id: note.id) }
                    .buttonStyle(.bordered)
            }

            Spacer(minLength: 8)

            Button {
                model.lock()
            } label: {
                Image(systemName: "lock.open")
            }
            .help(model.lockStatus.isEmpty ? "Lock (⌘L)" : "\(model.lockStatus). Click to lock now (⌘L).")
            .accessibilityLabel("Lock Offline")
            .accessibilityValue(model.lockStatus)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                HardenedTextField(
                    text: searchText,
                    placeholder: "Search",
                    accessibilityLabel: "Search notes",
                    focusToken: model.searchFocusToken,
                    onCommit: { model.editor.focus() },
                    onCancel: { model.setSearchText("") }
                )
                .frame(height: 20)
                if !model.searchText.isEmpty {
                    Button {
                        model.setSearchText("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 230, height: 30)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
            .disabled(model.isTrashSelected)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .frame(height: Chrome.barHeight)
    }

    /// The date, a large title and the tags, above the note's text.
    private var noteHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note {
                Text(isTrashed ? "In the Trash" : Self.dateFormatter.string(from: note.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 6)
                    .accessibilityLabel(isTrashed ? "In the Trash" : "Last edited \(Self.dateFormatter.string(from: note.updatedAt))")
            }
            HardenedTextField(
                text: $model.titleDraft,
                placeholder: "Title",
                font: settings.typography.font(size: titleSize, weight: .bold),
                accessibilityLabel: "Note title",
                focusToken: model.titleFocusToken,
                onCommit: { model.editor.focus() },
                onEndEditing: { model.saveNow() }
            )
            .frame(height: titleSize + 10)
            .onChange(of: model.titleDraft) { model.titleDidChange() }

            HStack(spacing: 5) {
                Image(systemName: "number")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                HardenedTextField(
                    text: $model.tagsDraft,
                    placeholder: "Add tags, separated by commas",
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    accessibilityLabel: "Tags",
                    onCommit: {
                        model.commitTags()
                        model.editor.focus()
                    },
                    onEndEditing: { model.commitTags() }
                )
                .frame(height: 18)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .disabled(isTrashed)
    }

    private var titleSize: CGFloat {
        (settings.typography.size * 1.6).rounded()
    }

    private var footer: some View {
        HStack {
            if note != nil {
                Text(model.wordCount == 1 ? "1 word" : "\(model.wordCount) words")
                    .accessibilityLabel("Word count: \(model.wordCount)")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 24)
    }
}
