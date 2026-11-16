import Foundation
import AppKit
import AVFoundation
import ReaderCore

@MainActor
final class NarrationController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let runtimeRoot = LibraryStore.defaultRoot.deletingLastPathComponent()
        .appendingPathComponent("ReaderRuntime", isDirectory: true)
    static let voices: [(id: String, name: String)] = [("af_heart", "Heart · American"), ("af_bella", "Bella · American"), ("am_michael", "Michael · American"), ("bf_emma", "Emma · British"), ("bm_george", "George · British")]
    @Published var isBusy = false
    @Published var phase = "Ready"
    @Published var fraction: Double = 0
    @Published var message = ""
    @Published var error: String?
    @Published var activeTitle = ""
    @Published var isPlaying = false
    @Published var playbackItemID: String?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var modelPath = UserDefaults.standard.string(forKey: "narrationModels") ?? runtimeRoot.appendingPathComponent("Models").path {
        didSet { UserDefaults.standard.set(modelPath, forKey: "narrationModels") }
    }
    @Published var voice = UserDefaults.standard.string(forKey: "narrationVoice") ?? "af_heart" {
        didSet { UserDefaults.standard.set(voice, forKey: "narrationVoice") }
    }
    @Published var speed = UserDefaults.standard.object(forKey: "narrationSpeed") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(speed, forKey: "narrationSpeed") }
    }
    @Published var keepReferences = false
    @Published var cleanText = true
    var afterStop: (() -> Void)?
    var onSaved: (() -> Void)?
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var outputBuffer = ""
    private var errorTail = ""
    private var workerError: String?
    private var cancelled = false
    private var player: AVAudioPlayer?
    private var playbackNarrationID: String?
    private var playbackStore: LibraryStore?
    private var timer: Timer?
    private var lastPositionSave = Date.distantPast
    private(set) var jobDirectory: URL?

    var runtimeDirectory: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("NarrationRuntime")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("runtime/bin/python3.11").path) { return bundled }
        return Self.runtimeRoot
    }
    var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: runtimeDirectory.appendingPathComponent("runtime/bin/python3.11").path)
            && FileManager.default.isExecutableFile(atPath: runtimeDirectory.appendingPathComponent("bin/ffmpeg").path)
            && FileManager.default.fileExists(atPath: URL(fileURLWithPath: modelPath).appendingPathComponent("speech").path)
            && FileManager.default.fileExists(atPath: URL(fileURLWithPath: modelPath).appendingPathComponent("cleanup").path)
    }
    func chooseModels() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a local models folder containing speech and cleanup."
        panel.begin { [weak self] response in
            MainActor.assumeIsolated { if response == .OK, let url = panel.url { self?.modelPath = url.path } }
        }
    }
    func generate(item: ReaderItem, store: LibraryStore) {
        guard !isBusy else { return }
        guard isReady else { error = "The local narration runtime or models are missing. Run scripts/setup-narration.sh in the Reader project, or locate an existing model folder."; return }
        guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "This document has no extracted text. Scanned PDFs need OCR before they can be narrated."; return }
        stopPlayback()
        cancelled = false; outputBuffer = ""; errorTail = ""; workerError = nil; error = nil
        activeTitle = item.title; fraction = 0; phase = "Preparing text"; message = "Starting local text preparation…"
        let job = store.root.appendingPathComponent("Work/Narration-\(UUID().uuidString)")
        jobDirectory = job
        do {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            let input = job.appendingPathComponent("input.txt")
            try Data(item.text.utf8).write(to: input, options: .atomic)
            let request = ["itemID": item.id, "title": item.title, "sourceURL": item.originalURL ?? "", "voice": voice, "speed": String(speed)]
            try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys]).write(to: job.appendingPathComponent("request.json"), options: .atomic)
            guard let worker = ReaderResources.bundle.url(forResource: "narration_worker", withExtension: "py", subdirectory: "Resources/Narration") else { throw LibraryError.io("The bundled narration worker is missing. Rebuild Reader.") }
            let task = Process(); task.executableURL = runtimeDirectory.appendingPathComponent("runtime/bin/python3.11")
            var arguments = ["-I", "-B", worker.path, "--job", job.path, "--text", input.path, "--title", item.title, "--voice", voice, "--speed", String(speed), "--models", modelPath, "--ffmpeg", runtimeDirectory.appendingPathComponent("bin/ffmpeg").path]
            if item.kind == .pdf { arguments += ["--pdf", try store.contentURL(for: item).path] }
            arguments += ["--item-id", item.id]
            if keepReferences { arguments.append("--keep-references") }
            if !cleanText { arguments.append("--no-cleanup") }
            task.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"; environment["PYTHONUNBUFFERED"] = "1"
            environment["TOKENIZERS_PARALLELISM"] = "false"
            task.environment = environment
            let stdout = Pipe(), stderr = Pipe(); output = stdout; errors = stderr
            task.standardOutput = stdout; task.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.consume(data) }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in if let self { self.errorTail = String((self.errorTail + String(decoding: data, as: UTF8.self)).suffix(12_000)) } }
            }
            let selectedVoice = voice, selectedSpeed = speed
            task.terminationHandler = { [weak self] task in
                Task { @MainActor in await self?.finish(status: task.terminationStatus, itemID: item.id, store: store, job: job, voice: selectedVoice, speed: selectedSpeed) }
            }
            process = task; isBusy = true
            try task.run()
        } catch {
            output?.fileHandleForReading.readabilityHandler = nil; errors?.fileHandleForReading.readabilityHandler = nil
            output = nil; errors = nil; process = nil; isBusy = false; self.error = error.localizedDescription; phase = "Could not start"
        }
    }
    private func consume(_ data: Data) {
        outputBuffer += String(decoding: data, as: UTF8.self)
        while let end = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<end]); outputBuffer.removeSubrange(...end)
            guard let bytes = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
            if let stage = event["stage"] as? String {
                if stage == "error" { workerError = event["message"] as? String }
                switch stage { case "preparing": phase = "Preparing text"; case "voicing": phase = "Generating narration"; case "encoding": phase = "Building MP3"; case "complete": phase = "Saving narration"; default: break }
            }
            if let f = event["fraction"] as? Double { fraction = min(1, max(0, f)) }
            if let description = event["message"] as? String { message = description }
        }
    }
    private func finish(status: Int32, itemID: String, store: LibraryStore, job: URL, voice: String, speed: Double) async {
        output?.fileHandleForReading.readabilityHandler = nil; errors?.fileHandleForReading.readabilityHandler = nil
        process = nil; output = nil; errors = nil
        defer {
            isBusy = false
            let completion = afterStop; afterStop = nil; completion?()
        }
        if cancelled { phase = "Cancelled"; message = "The existing narration has been kept."; return }
        guard status == 0 else {
            phase = "Narration failed"
            if !errorTail.isEmpty { try? Data(errorTail.utf8).write(to: job.appendingPathComponent("diagnostics.log"), options: .atomic) }
            let detail = workerError ?? (errorTail.isEmpty ? message : String(errorTail.suffix(3000)))
            error = "Narration could not finish. Your document and any previous MP3 are safe.\n\n" + detail
            return
        }
        do {
            let metadataURL = job.appendingPathComponent("metadata.json")
            let metadata = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))) as? [String: Any]
            let duration = metadata?["duration"] as? Double
            if playbackItemID == itemID { stopPlayback() }
            _ = try await Task.detached(priority: .userInitiated) { try store.saveNarration(itemID: itemID, from: job, voice: voice, speed: speed, duration: duration) }.value
            // Only remove a staged job after its complete managed copy is committed.
            try? FileManager.default.removeItem(at: job)
            jobDirectory = nil; phase = "Narration saved"; fraction = 1; message = "MP3 and prepared text are saved in your library."
            if let note = metadata?["extractionNote"] as? String, note.localizedCaseInsensitiveContains("no readable text") { message += " " + note + ". Those pages need OCR for narration." }
            onSaved?()
        } catch {
            phase = "Audio needs recovery"
            self.error = "The generated audio is preserved at \(job.path), but could not be added to the library.\n\n\(error.localizedDescription)"
        }
    }
    func cancel() {
        guard let process, process.isRunning else { return }
        cancelled = true; message = "Cancelling the local narration…"; process.terminate()
    }
    func togglePlayback(item: ReaderItem, store: LibraryStore) {
        guard !isBusy else { return }
        let latest = (try? store.item(id: item.id)) ?? item
        if playbackItemID != item.id || playbackNarrationID != latest.narration?.id || player == nil {
            stopPlayback()
            do {
                guard let url = try store.narrationAudioURL(for: latest) else { return }
                let next = try AVAudioPlayer(contentsOf: url); next.delegate = self; next.prepareToPlay()
                next.currentTime = min(latest.narration?.playbackPosition ?? 0, max(0, next.duration - 0.1))
                player = next; playbackStore = store; playbackItemID = item.id; playbackNarrationID = latest.narration?.id; duration = next.duration; position = next.currentTime
            } catch { self.error = "The saved narration could not be opened: " + error.localizedDescription; return }
        }
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false; timer?.invalidate(); timer = nil; savePlaybackPosition() }
        else { if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }; player.play(); isPlaying = true; startTimer() }
    }
    func seek(_ seconds: Double) { player?.currentTime = max(0, min(seconds, duration)); position = player?.currentTime ?? 0; savePlaybackPosition() }
    func stopPlayback() {
        savePlaybackPosition(); player?.stop(); player = nil; timer?.invalidate(); timer = nil
        isPlaying = false; playbackItemID = nil; playbackNarrationID = nil; playbackStore = nil; position = 0; duration = 0
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = self.player?.currentTime ?? 0
                if Date().timeIntervalSince(self.lastPositionSave) > 5 { self.savePlaybackPosition() }
            }
        }
    }
    func savePlaybackPosition() {
        guard let id = playbackItemID, let player, let store = playbackStore else { return }
        do { try store.saveNarrationPosition(itemID: id, seconds: player.currentTime); lastPositionSave = Date() }
        catch { self.error = "Audio playback position could not be saved: " + error.localizedDescription }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.isPlaying = false; self.position = self.duration; self.savePlaybackPosition(); self.timer?.invalidate()
        }
    }
    func revealAudio(item: ReaderItem, store: LibraryStore) {
        do { if let url = try store.narrationAudioURL(for: item) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        catch { self.error = error.localizedDescription }
    }
    func exportAudio(item: ReaderItem, store: LibraryStore) {
        do {
            guard let source = try store.narrationAudioURL(for: item) else { return }
            let panel = NSSavePanel(); panel.directoryURL = store.root.appendingPathComponent("Exports")
            let safeTitle = item.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            panel.nameFieldStringValue = String(safeTitle.prefix(90)) + ".mp3"; panel.allowedContentTypes = [.mp3]
            panel.begin { [weak self] response in
                MainActor.assumeIsolated {
                    guard response == .OK, let target = panel.url else { return }
                    do { let data = try Data(contentsOf: source, options: .mappedIfSafe); try data.write(to: target, options: .atomic) }
                    catch { self?.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
