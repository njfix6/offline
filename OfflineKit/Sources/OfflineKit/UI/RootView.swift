import OfflineCore
import SwiftUI

/// Chooses the screen for the current phase. While locked, no view that can
/// hold note content exists in the hierarchy at all.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .starting:
                Color(nsColor: .windowBackgroundColor)
            case .onboarding:
                OnboardingView()
            case .locked:
                UnlockView()
            case .keyMissing:
                KeyMissingView()
            case .unlocked:
                MainView()
            }

            if let prompt = model.prompt {
                PromptOverlay(prompt: prompt)
                    .id(prompt.id)
            }
            if let message = model.busyMessage {
                BusyOverlay(message: message)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .writingToolsBehavior(.disabled)
    }
}

/// The locked screen: the app's name, a lock and one button. Nothing from any
/// note is shown.
struct UnlockView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Offline")
                .font(.system(size: 30, weight: .semibold))
            Text("Locked")
                .foregroundStyle(.secondary)
            Button {
                model.unlock()
            } label: {
                Text(model.isAuthenticating ? "Waiting for Touch ID or Password…" : "Unlock")
                    .frame(minWidth: 140)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isAuthenticating)
            .accessibilityHint("Unlocks your notes with Touch ID or your Mac password")

            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Shown when the encrypted database is present but its key is not.
struct KeyMissingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The encryption key is missing")
                .font(.title2.weight(.semibold))
            Text("""
                Your notes are still on this Mac, encrypted, but the key that opens them is no longer \
                in the Keychain. Without that key they cannot be read by Offline or by anyone else.

                If you have an encrypted backup, start a fresh vault and then choose \
                File › Restore from Encrypted Backup. The old encrypted file is kept, not deleted.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("Keep Old File Aside and Start Fresh") {
                if model.confirm(
                    "Start a fresh vault?",
                    detail: "The old encrypted database is moved into a folder next to the new one. It is not deleted, but it cannot be opened without its key.",
                    button: "Start Fresh"
                ) {
                    model.startFreshAfterKeyLoss()
                }
            }
            .controlSize(.large)
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// First launch: what Offline protects, what it cannot, then the key.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    private struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let text: String
    }

    private let protects = [
        Point(symbol: "wifi.slash", title: "Notes never leave this Mac",
              text: "Offline has no network access at all. No sync, no accounts, no analytics."),
        Point(symbol: "lock.doc", title: "Encrypted on disk",
              text: "Notes and images are stored in one encrypted file. The key lives in your Keychain and needs Touch ID or your Mac password."),
        Point(symbol: "eye.slash", title: "Hidden from AI and search",
              text: "Apple Intelligence, Writing Tools, Siri and Spotlight are given nothing to read. There are no AI features."),
        Point(symbol: "timer", title: "Locks itself",
              text: "After a few idle minutes, on sleep and on screen lock, the notes close and the key is wiped from memory."),
    ]

    private let limits = [
        Point(symbol: "camera.viewfinder", title: "Screenshots are blocked only partly",
              text: "The window asks macOS to leave it out of screenshots and recordings. Some capture methods may ignore that."),
        Point(symbol: "doc.on.clipboard", title: "Copying is your choice",
              text: "Copied text is marked private so clipboard managers skip it, but anything you paste elsewhere is out of Offline's hands."),
        Point(symbol: "exclamationmark.shield", title: "Not a defence against a compromised Mac",
              text: "Malware, keyloggers and apps you have given Accessibility or full control can see what is on screen while Offline is unlocked."),
        Point(symbol: "key", title: "No key, no notes",
              text: "If the Keychain key is lost, only an encrypted backup (File menu) can bring your notes back. There is no recovery service."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Offline")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Private notes that stay on this Mac. Every protection is on from the start and cannot be turned off.")
                        .foregroundStyle(.secondary)
                }

                section("What Offline protects", points: protects, tint: .green)
                section("What it cannot protect", points: limits, tint: .orange)

                HStack(spacing: 14) {
                    Button {
                        model.createVault()
                    } label: {
                        Text(model.isAuthenticating ? "Waiting for Touch ID or Password…" : "Create Key with Touch ID")
                            .frame(minWidth: 200)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isAuthenticating)

                    if let notice = model.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(36)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section(_ title: String, points: [Point], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(points) { point in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: point.symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.title).fontWeight(.medium)
                        Text(point.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Covers the window while slow work (backup, import) runs.
struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(message)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
    }
}

/// An in-window dialog asking for a name or a passphrase.
struct PromptOverlay: View {
    @EnvironmentObject private var model: AppModel
    let prompt: Prompt

    @State private var text = ""
    @State private var confirmation = ""
    @State private var focusToken = 0
    @FocusState private var secureFocused: Bool

    private var problem: String? {
        switch prompt.kind {
        case .text:
            return nil
        case .passphrase:
            return nil
        case .newPassphrase:
            if text.count < EncryptedBackup.minimumPassphraseLength {
                return "At least \(EncryptedBackup.minimumPassphraseLength) characters."
            }
            return text == confirmation ? nil : "The two passphrases do not match."
        }
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && problem == nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 14) {
                Text(prompt.title).font(.headline)
                if !prompt.message.isEmpty {
                    Text(prompt.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch prompt.kind {
                case .text:
                    HardenedTextField(
                        text: $text,
                        placeholder: prompt.placeholder,
                        isBordered: true,
                        focusToken: focusToken,
                        onCommit: submit,
                        onCancel: cancel
                    )
                    .frame(height: 24)
                case .passphrase, .newPassphrase:
                    SecureField(prompt.placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($secureFocused)
                        .onSubmit(submit)
                    if prompt.kind == .newPassphrase {
                        SecureField("Repeat passphrase", text: $confirmation)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submit)
                        Text(problem ?? " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                    Button(prompt.confirmTitle, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
            .padding(22)
            .frame(width: 400)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
        }
        .onAppear {
            text = prompt.initialText
            focusToken += 1
            secureFocused = true
        }
        .accessibilityAddTraits(.isModal)
    }

    private func submit() {
        guard canSubmit else { return }
        let value = prompt.kind == .text ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        model.prompt = nil
        text = ""
        confirmation = ""
        prompt.onSubmit(value)
    }

    private func cancel() {
        text = ""
        confirmation = ""
        model.prompt = nil
    }
}
