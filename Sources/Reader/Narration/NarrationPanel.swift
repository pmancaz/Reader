import SwiftUI
import ReaderCore

/// Optional details and export tools. Creation/playback live in the document header.
struct NarrationPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var narration: NarrationController
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var preparedText = ""
    @ViewState<Bool> private var showScript = false
    @ViewState<String> private var extractionWarning = ""
    @ViewState<String> private var savedSources = ""
    var item: ReaderItem? { model.selectedItem }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Narration details").font(.title2.weight(.semibold))
                    Text(item?.title ?? "Select a document").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let item, item.narration != nil, let store = model.store {
                playback(item: item, store: store)
            } else if let item, !narration.isGenerating(item.id) {
                Text("No narration saved yet. Create narration uses the defaults in Settings and runs while you keep reading.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Create narration") { model.performNarrationAction(); dismiss() }
                    .disabled(!model.canPerformNarrationAction)
            }
            if let item, narration.isGenerating(item.id) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Generating narration…").font(.headline); Spacer(); Button("Cancel") { narration.cancel() } }
                    ProgressView(value: narration.fraction)
                    Text(narration.phase).font(.caption).foregroundStyle(.secondary)
                    Text("You can close this panel and keep reading.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                SettingsLink { Text("Narration Settings…") }
                Spacer()
                if let item, item.narration != nil {
                    Button("Create new narration") { model.regenerateNarration(item); dismiss() }
                        .disabled(narration.isBusy || model.importing)
                }
            }
            if !preparedText.isEmpty {
                DisclosureGroup("Prepared listening text", isExpanded: $showScript) {
                    ScrollView {
                        Text(preparedText).font(.system(size: 13, design: .serif)).lineSpacing(5)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(height: 230).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.padding(24).frame(width: 650)
            .task(id: item?.narration?.id) { loadPreparedText() }
            .alert("Narration", isPresented: Binding(get: { narration.errorItemID == item?.id && narration.error != nil }, set: { if !$0 { narration.error = nil } })) {
                Button("OK") { narration.error = nil }
            } message: { Text(narration.error ?? "") }
    }
    @ViewBuilder func playback(item: ReaderItem, store: LibraryStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button { narration.togglePlayback(item: item, store: store) } label: {
                    Label(narration.isPlaying && narration.playbackItemID == item.id ? "Pause" : "Play",
                          systemImage: narration.isPlaying && narration.playbackItemID == item.id ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderedProminent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved MP3").font(.headline)
                    Text(savedSources + " · AI-generated voice").font(.caption).foregroundStyle(.secondary)
                    Text("\(NarrationController.voices.first(where: { $0.id == item.narration?.voice })?.name ?? item.narration?.voice ?? "Local voice") · \(item.narration?.speed ?? 1, specifier: "%.1f")× · \(item.narration?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Export MP3…") { narration.exportAudio(item: item, store: store) }
                    Button("Reveal MP3 in Finder") { narration.revealAudio(item: item, store: store) }
                } label: { Image(systemName: "ellipsis") }.fixedSize().help("Audio export options")
            }
            NarrationSeekBar(item: item, store: store, narration: narration)
            if !extractionWarning.isEmpty {
                Label(extractionWarning + ". Those pages need OCR to be included in the narration.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    func loadPreparedText() {
        guard let item, let url = try? model.store?.narrationScriptURL(for: item) else { preparedText = ""; extractionWarning = ""; return }
        preparedText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let metadataURL = url.deletingLastPathComponent().appendingPathComponent("metadata.json")
        let metadata = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))) as? [String: Any]
        let cleanup = (metadata?["cleanupEngine"] as? String ?? "").hasPrefix("gpt-") ? "OpenAI" : "Local"
        let audio = (metadata?["engine"] as? String ?? "").hasPrefix("gpt-") ? "OpenAI" : "Local"
        savedSources = "Cleanup: \(cleanup) · Audio: \(audio)"
        let note = metadata?["extractionNote"] as? String ?? ""
        extractionWarning = note.localizedCaseInsensitiveContains("no readable text") ? note : ""
    }
}
