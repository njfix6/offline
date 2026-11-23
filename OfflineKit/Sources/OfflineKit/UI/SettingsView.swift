import OfflineCore
import SwiftUI

/// The whole of the app's preferences. There is deliberately nothing here
/// that weakens a protection.
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Security") {
                Stepper(value: $settings.autoLockMinutes, in: LockPolicy.minimumMinutes...LockPolicy.maximumMinutes) {
                    Text("Lock after \(settings.autoLockMinutes) minute\(settings.autoLockMinutes == 1 ? "" : "s") without activity")
                }
                Text("Offline also locks when the Mac sleeps, the screen locks or another user switches in. Auto-lock cannot be turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Leave notes out of Time Machine backups", isOn: $settings.excludeFromTimeMachine)
                Text("Off by default. Time Machine only ever copies the encrypted file, which is useless without the key in this Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Editor") {
                Picker("Font", selection: $settings.typography.family) {
                    ForEach(EditorTypography.Family.allCases) { family in
                        Text(family.displayName).tag(family)
                    }
                }
                Stepper(
                    value: $settings.typography.size,
                    in: EditorTypography.minimumSize...EditorTypography.maximumSize,
                    step: 1
                ) {
                    Text("Size: \(Int(settings.typography.size)) pt")
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .writingToolsBehavior(.disabled)
    }
}
