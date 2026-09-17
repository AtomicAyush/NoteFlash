import SwiftUI

struct SettingsView: View {
    private enum KeyStatus: Equatable {
        case idle
        case checking
        case valid
        case invalid(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(DocSyncService.self) private var sync
    @AppStorage(AIEngineKind.storageKey) private var engine: AIEngineKind = .apple

    @State private var apiKeyInput = ""
    @State private var hasSavedKey = KeychainStore.string(for: .anthropicAPIKey) != nil
    @State private var keyStatus: KeyStatus = .idle
    @State private var isCheckingDocs = false

    var body: some View {
        NavigationStack {
            Form {
                engineSection
                if engine == .claude || hasSavedKey {
                    claudeSection
                }
                GoogleAccountSection()
                syncSection
                Section {
                    NavigationLink("Processing Log") { ProcessingLogView() }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("A record of recent flashcard jobs, including why any of them stopped.")
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    LabeledContent("AI model", value: engine == .claude ? AppConfig.claudeModel : "Apple on-device model")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var engineSection: some View {
        Section {
            Picker("Write cards with", selection: $engine) {
                ForEach(AIEngineKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            if engine == .apple {
                if let problem = AppleFlashcardEngine.unavailableReason {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    Label("Ready on this iPhone", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("AI Model")
        } footer: {
            switch engine {
            case .apple:
                Text("Free and private: cards are written on this iPhone and your notes never leave it. Requires an iPhone that supports Apple Intelligence. Long notes are handled in sections.")
            case .claude:
                Text("Uses Claude with your own API key (usage is billed to your Anthropic account). Best for very long notes, scanned PDFs, and diagrams.")
            }
        }
    }

    private var claudeSection: some View {
        Section {
            SecureField(hasSavedKey ? "Paste a new key to replace" : "sk-ant-…", text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveKey)

            if !apiKeyInput.isEmpty {
                Button("Save Key", action: saveKey)
            }

            if hasSavedKey {
                HStack {
                    Button("Test Connection") { Task { await testKey() } }
                        .disabled(keyStatus == .checking)
                    Spacer()
                    switch keyStatus {
                    case .idle:
                        Label("Saved", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                    case .checking:
                        ProgressView()
                    case .valid:
                        Label("Working", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .invalid:
                        Label("Failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if case .invalid(let message) = keyStatus {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("Remove Key", role: .destructive) {
                    KeychainStore.set(nil as String?, for: .anthropicAPIKey)
                    hasSavedKey = false
                    keyStatus = .idle
                }
            }
        } header: {
            Text("Claude API Key")
        } footer: {
            Text("Only needed when Claude is selected. Create a key at [console.anthropic.com](https://console.anthropic.com/settings/keys); it's stored only in this device's Keychain.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task {
                    isCheckingDocs = true
                    await sync.syncAllLinkedDecks()
                    isCheckingDocs = false
                }
            } label: {
                HStack {
                    Text("Check Linked Docs Now")
                    if isCheckingDocs {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isCheckingDocs)
        } header: {
            Text("Google Doc Sync")
        } footer: {
            Text("While NoteFlash is open, linked docs are checked every 2 minutes. iOS also wakes NoteFlash in the background from time to time to check. When a doc changes, the selected AI model updates only the affected cards.")
        }
    }

    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        KeychainStore.set(key, for: .anthropicAPIKey)
        apiKeyInput = ""
        hasSavedKey = true
        Task { await testKey() }
    }

    private func testKey() async {
        keyStatus = .checking
        do {
            try await AnthropicClient.fromKeychain().verifyKey()
            keyStatus = .valid
        } catch {
            keyStatus = .invalid(error.localizedDescription)
        }
    }
}
