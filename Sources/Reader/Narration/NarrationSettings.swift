import SwiftUI

struct NarrationSettings: View {
    @ObservedObject var narration: NarrationController
    @ViewState private var keyDraft = ""
    @ViewState private var removeKey = false
    var body: some View {
        Form {
            Section {
                Picker("Text cleanup", selection: $narration.cleanupProvider) {
                    ForEach(NarrationProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Picker("Narration audio", selection: $narration.speechProvider) {
                    ForEach(NarrationProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                Label(narration.readinessIssue ?? "Selected narration services are ready", systemImage: narration.isReady ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("How to create narration") } footer: {
                Text("Choose each stage independently. Local models run on this Mac. OpenAI sends text over the internet and uses your paid API account. Changes apply to the next narration.")
            }
            Section {
                Picker("Voice", selection: $narration.voice) {
                    ForEach(narration.availableVoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speed · \(narration.speed, specifier: "%.1f")×")
                    Slider(value: $narration.speed, in: 0.6...1.5, step: 0.1).accessibilityLabel("Default narration speed")
                }
                Toggle("Remove boilerplate and clean listening text", isOn: $narration.cleanText)
                Toggle("Include references and citations", isOn: $narration.keepReferences)
            } header: { Text("Narration defaults") } footer: {
                Text("Create narration uses these settings. Existing recordings keep their voice, speed and saved audio. Each audio service remembers its own voice.")
            }
            Section {
                Text(narration.hasAPIKey ? "An OpenAI API key is configured." : "Add your OpenAI API key to use either API stage.").font(.callout)
                HStack {
                    SecureField("Enter a new OpenAI API key", text: $keyDraft).accessibilityLabel("OpenAI API key")
                    Button("Save key") { if narration.saveAPIKey(keyDraft) { keyDraft = "" } }.disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Keys entered here are saved in macOS Keychain. An existing Reader .env.local key also works. Keys are never included in library backups.").font(.caption).foregroundStyle(.secondary)
                if ReaderAPIKeychain.read() != nil { Button("Remove Keychain key…") { removeKey = true } }
                if !narration.keyStatus.isEmpty { Text(narration.keyStatus).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("OpenAI models") {
                    Text("Text cleanup: \(OpenAINarrationOptions.cleanupModel)\nNarration audio: \(OpenAINarrationOptions.speechModel)").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("OpenAI API key") }
            if narration.cleanupProvider == .local || narration.speechProvider == .local {
                Section {
                    DisclosureGroup("Local model location") {
                        Text(narration.modelPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Locate models…") { narration.chooseModels() }
                    }
                } header: { Text("Local models") }
            }
            Section { Button("Restore narration defaults") { narration.resetGenerationDefaults() } }
        }.formStyle(.grouped).padding(.vertical, 8).frame(width: 600, height: 650)
            .confirmationDialog("Remove the OpenAI API key from macOS Keychain?", isPresented: $removeKey) {
                Button("Remove Keychain key", role: .destructive) { narration.removeAPIKey() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Your .env.local file and OpenAI account are unchanged.") }
    }
}
