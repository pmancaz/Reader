import SwiftUI
import ReaderCore

/// The main article player stays in the document header; it never opens a sheet.
struct DocumentNarrationPlayer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var narration: NarrationController
    let item: ReaderItem
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Next narration · Cleanup: \(narration.cleanupProvider == .local ? "Local" : "OpenAI") · Audio: \(narration.speechProvider == .local ? "Local" : "OpenAI")").font(.caption2).foregroundStyle(.secondary)
                .help("These defaults apply when creating a new narration. Existing recordings keep their saved audio.")
            HStack(spacing: 10) {
                if narration.isGenerating(item.id) {
                    ProgressView(value: narration.fraction).frame(width: 85)
                        .accessibilityLabel("Narration generation progress")
                    Text("Generating narration…").font(.callout)
                    Spacer(minLength: 0)
                    Button { narration.cancel() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Cancel narration generation").accessibilityLabel("Cancel narration generation")
                } else {
                    Button { model.performNarrationAction() } label: {
                        Label(item.narration == nil ? "Create narration" : (isPlaying ? "Pause narration" : "Play narration"),
                              systemImage: item.narration == nil ? "waveform" : (isPlaying ? "pause.fill" : "play.fill"))
                    }.disabled(!model.canPerformNarrationAction)
                        .help(item.narration == nil ? (narration.usesOpenAI ? "Send this document’s text to OpenAI and create narration using your Settings defaults. API usage charges apply." : "Create narration in the background using your Settings defaults.") : "Play the narration saved with this document.")
                    Spacer(minLength: 0)
                }
                Menu {
                    if item.narration != nil, let store = model.store {
                        Button("Export MP3…") { narration.exportAudio(item: item, store: store) }
                        Button("Reveal MP3 in Finder") { narration.revealAudio(item: item, store: store) }
                        Button("Narration details…") { model.showNarration = true }
                        Divider()
                        Button("Create new narration") { model.regenerateNarration(item) }.disabled(narration.isBusy || model.importing)
                        Divider()
                    } else if narration.errorItemID == item.id && narration.error != nil {
                        Button("Narration details…") { model.showNarration = true }
                    }
                    SettingsLink { Text("Narration Settings…") }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .help("Narration options").accessibilityLabel("Narration options")
            }.controlSize(.small)
            if item.narration != nil, let store = model.store {
                NarrationSeekBar(item: item, store: store, narration: narration)
            }
            if narration.errorItemID == item.id, narration.error != nil {
                HStack(alignment: .firstTextBaseline) {
                    Label("Narration needs attention", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    Button("Details…") { model.showNarration = true }.font(.caption).buttonStyle(.link)
                }
            } else if narration.isBusy && !narration.isGenerating(item.id) && item.narration == nil {
                Text("Another document is generating narration. You can keep reading.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }
    private var isPlaying: Bool { narration.isPlaying && narration.playbackItemID == item.id }
}

struct NarrationSeekBar: View {
    let item: ReaderItem
    let store: LibraryStore
    @ObservedObject var narration: NarrationController
    private var duration: Double { max(0, narration.playbackDuration(for: item)) }
    private var position: Double { min(duration, max(0, narration.playbackPosition(for: item))) }
    var body: some View {
        HStack(spacing: 9) {
            Text(NarrationController.time(position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { position }, set: { narration.seek($0, item: item, store: store) }), in: 0...max(1, duration))
                .disabled(duration <= 0).accessibilityLabel("Narration playback position")
                .accessibilityValue("\(NarrationController.time(position)) of \(NarrationController.time(duration))")
            Text(NarrationController.time(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Keeps the running job/player reachable when the reader selects another paper.
struct BackgroundNarrationStatus: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var narration: NarrationController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if narration.isBusy, narration.activeItemID != model.selectedID {
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text("Generating narration…").font(.caption); Spacer(); Button("Show") { model.showNarrationDocument(narration.activeItemID) }.font(.caption).buttonStyle(.link) }
                    ProgressView(value: narration.fraction).accessibilityLabel("Background narration generation progress")
                    Text(narration.activeTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let id = narration.playbackItemID, id != model.selectedID,
               let playing = model.items.first(where: { $0.id == id }), let store = model.store {
                HStack(spacing: 8) {
                    Button { narration.togglePlayback(item: playing, store: store) } label: { Image(systemName: narration.isPlaying ? "pause.fill" : "play.fill") }
                        .buttonStyle(.borderless).help(narration.isPlaying ? "Pause narration" : "Play narration")
                    Button { model.showNarrationDocument(id) } label: { Text(playing.title).lineLimit(1) }.buttonStyle(.plain).font(.caption)
                    Text(NarrationController.time(narration.position)).monospacedDigit().font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
