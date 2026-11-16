import SwiftUI
import ReaderCore

struct NarrationPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var narration: NarrationController
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var preparedText = ""
    @ViewState<Bool> private var showScript = false
    @ViewState<String> private var extractionWarning = ""
    var item: ReaderItem? { model.selectedItem }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Narration").font(.title2.weight(.semibold)); Text(item?.title ?? "Select a document").foregroundStyle(.secondary).lineLimit(2) }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let item, item.narration != nil, let store = model.store {
                playback(item: item, store: store)
                Divider()
            }
            if narration.isBusy {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(narration.phase).font(.headline); Spacer(); Button("Cancel") { narration.cancel() } }
                    Text(narration.activeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: narration.fraction)
                    Text(narration.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("You can close this panel and keep reading.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 24) {
                    Picker("Voice", selection: $narration.voice) { ForEach(NarrationController.voices, id: \.id) { voice in Text(voice.name).tag(voice.id) } }
                    VStack(alignment: .leading, spacing: 5) { Text("Speed · \(narration.speed, specifier: "%.1f")×").font(.callout); Slider(value: $narration.speed, in: 0.6...1.5, step: 0.1).frame(width: 150).accessibilityLabel("Narration generation speed") }
                }
                Toggle("Remove boilerplate and clean listening text", isOn: $narration.cleanText).font(.callout)
                Toggle("Include references and citations", isOn: $narration.keepReferences).font(.callout)
                Text("Reader prepares a listening script, removes page furniture and publisher boilerplate, then generates speech locally. The source document stays intact.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !narration.isReady {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Local narration needs its runtime and models", systemImage: "externaldrive.badge.exclamationmark").font(.headline)
                        Text("Run scripts/setup-narration.sh from the Reader project to install the local components, or choose an existing folder containing the speech and cleanup models.").font(.callout).foregroundStyle(.secondary)
                        Button("Locate models…") { narration.chooseModels() }
                    }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    if !narration.message.isEmpty { Text(narration.message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Button(item?.narration == nil ? "Generate MP3" : "Generate new narration") {
                        if let item, let store = model.store { narration.generate(item: item, store: store) }
                    }.keyboardShortcut(.return, modifiers: [.command]).disabled(item == nil || model.importing || !narration.isReady)
                }
            }
            if !preparedText.isEmpty {
                DisclosureGroup("Prepared listening text", isExpanded: $showScript) {
                    ScrollView { Text(preparedText).font(.system(size: 13, design: .serif)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(height: 230).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.padding(24).frame(width: 650)
            .task(id: item?.narration?.id) { loadPreparedText() }
            .alert("Narration", isPresented: Binding(get: { narration.error != nil }, set: { if !$0 { narration.error = nil } })) { Button("OK") { narration.error = nil } } message: { Text(narration.error ?? "") }
    }
    @ViewBuilder func playback(item: ReaderItem, store: LibraryStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button { narration.togglePlayback(item: item, store: store) } label: { Label(narration.isPlaying && narration.playbackItemID == item.id ? "Pause" : "Play", systemImage: narration.isPlaying && narration.playbackItemID == item.id ? "pause.fill" : "play.fill") }.buttonStyle(.borderedProminent).disabled(narration.isBusy)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved MP3").font(.headline)
                    Text("\(NarrationController.voices.first(where: { $0.id == item.narration?.voice })?.name ?? item.narration?.voice ?? "Local voice") · \(item.narration?.speed ?? 1, specifier: "%.1f")× · \(item.narration?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu { Button("Export MP3…") { narration.exportAudio(item: item, store: store) }; Button("Reveal MP3 in Finder") { narration.revealAudio(item: item, store: store) } } label: { Image(systemName: "ellipsis") }.fixedSize().help("Audio export options")
            }
            if !extractionWarning.isEmpty {
                Label(extractionWarning + ". Those pages need OCR to be included in the narration.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if narration.playbackItemID == item.id, narration.duration > 0 {
                HStack {
                    Text(time(narration.position)).monospacedDigit().font(.caption)
                    Slider(value: Binding(get: { narration.position }, set: { narration.seek($0) }), in: 0...narration.duration).accessibilityLabel("Narration playback position")
                    Text(time(narration.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    func loadPreparedText() {
        guard let item, let url = try? model.store?.narrationScriptURL(for: item) else { preparedText = ""; extractionWarning = ""; return }
        preparedText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let metadataURL = url.deletingLastPathComponent().appendingPathComponent("metadata.json")
        let metadata = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))) as? [String: Any]
        let note = metadata?["extractionNote"] as? String ?? ""
        extractionWarning = note.localizedCaseInsensitiveContains("no readable text") ? note : ""
    }
    func time(_ seconds: Double) -> String { let total = Int(max(0, seconds)); return String(format: "%d:%02d", total / 60, total % 60) }
}
