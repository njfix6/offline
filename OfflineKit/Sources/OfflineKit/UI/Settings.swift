import AppKit
import Combine
import OfflineCore

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The app's few preferences, kept in `UserDefaults`. Nothing from a note is
/// ever stored here, and no preference can switch a protection off: the
/// auto-lock time is clamped to 1...60 minutes.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let autoLockMinutes = "autoLockMinutes"
        static let fontFamily = "editorFontFamily"
        static let fontSize = "editorFontSize"
        static let theme = "theme"
        static let sort = "noteSort"
        static let excludeFromTimeMachine = "excludeFromTimeMachine"
    }

    private let defaults: UserDefaults

    @Published var autoLockMinutes: Int {
        didSet {
            let clamped = LockPolicy.clamp(autoLockMinutes)
            if clamped != autoLockMinutes { autoLockMinutes = clamped }
            defaults.set(clamped, forKey: Key.autoLockMinutes)
        }
    }

    @Published var typography: EditorTypography {
        didSet {
            let size = min(max(typography.size, EditorTypography.minimumSize), EditorTypography.maximumSize)
            if size != typography.size { typography.size = size }
            defaults.set(typography.family.rawValue, forKey: Key.fontFamily)
            defaults.set(Double(size), forKey: Key.fontSize)
        }
    }

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.theme)
            NSApp.appearance = theme.appearance
        }
    }

    @Published var sort: NoteSort {
        didSet { defaults.set(sort.rawValue, forKey: Key.sort) }
    }

    /// Off by default: Time Machine only ever sees the encrypted file.
    @Published var excludeFromTimeMachine: Bool {
        didSet { defaults.set(excludeFromTimeMachine, forKey: Key.excludeFromTimeMachine) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMinutes = defaults.object(forKey: Key.autoLockMinutes) as? Int ?? LockPolicy.defaultMinutes
        autoLockMinutes = LockPolicy.clamp(storedMinutes)

        let family = defaults.string(forKey: Key.fontFamily).flatMap(EditorTypography.Family.init(rawValue:)) ?? .system
        let storedSize = defaults.object(forKey: Key.fontSize) as? Double ?? Double(EditorTypography.defaultSize)
        let size = min(max(CGFloat(storedSize), EditorTypography.minimumSize), EditorTypography.maximumSize)
        typography = EditorTypography(family: family, size: size)

        theme = defaults.string(forKey: Key.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        sort = defaults.string(forKey: Key.sort).flatMap(NoteSort.init(rawValue:)) ?? .modified
        excludeFromTimeMachine = defaults.bool(forKey: Key.excludeFromTimeMachine)
    }

    var lockPolicy: LockPolicy {
        LockPolicy(timeoutMinutes: autoLockMinutes)
    }
}
