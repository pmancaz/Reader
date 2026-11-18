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
    @Published private(set) var activeItemID: String?
    @Published private(set) var errorItemID: String?
    @Published var isPlaying = false
    @Published var playbackItemID: String?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    private let defaults: UserDefaults
    @Published var cleanupProvider: NarrationProvider {
        didSet { defaults.set(cleanupProvider.rawValue, forKey: "narrationCleanupProvider") }
    }
    @Published var speechProvider: NarrationProvider {
        didSet {
            defaults.set(speechProvider.rawValue, forKey: "narrationSpeechProvider")
            guard speechProvider != oldValue else { return }
            defaults.set(voice, forKey: oldValue == .local ? "narrationLocalVoice" : "narrationOpenAIVoice")
            let saved = defaults.string(forKey: speechProvider == .local ? "narrationLocalVoice" : "narrationOpenAIVoice")
            let choices = speechProvider == .local ? Self.voices.map(\.id) : OpenAINarrationOptions.voices
            voice = saved.flatMap { choices.contains($0) ? $0 : nil } ?? (speechProvider == .local ? "af_heart" : "marin")
        }
    }
    var usesOpenAI: Bool { cleanupProvider == .openAI || speechProvider == .openAI }
    var needsAPIKey: Bool { speechProvider == .openAI || (cleanupProvider == .openAI && (cleanText || !keepReferences)) }
    @Published var keyStatus = ""
    private let injectedOpenAIService: OpenAINarrationService?
    private var openAITask: Task<Void, Never>?
    var availableVoices: [(id: String, name: String)] {
        speechProvider == .openAI ? OpenAINarrationOptions.voices.map { ($0, $0.capitalized) } : Self.voices
    }
    @Published var modelPath: String {
        didSet { defaults.set(modelPath, forKey: "narrationModels") }
    }
    @Published var voice: String {
        didSet {
            defaults.set(voice, forKey: "narrationVoice")
            defaults.set(voice, forKey: speechProvider == .local ? "narrationLocalVoice" : "narrationOpenAIVoice")
        }
    }
    @Published var speed: Double {
        didSet { defaults.set(speed, forKey: "narrationSpeed") }
    }
    @Published var keepReferences: Bool {
        didSet { defaults.set(keepReferences, forKey: "narrationKeepReferences") }
    }
    @Published var cleanText: Bool {
        didSet { defaults.set(cleanText, forKey: "narrationCleanText") }
    }
    var afterStop: (() -> Void)?
    var onSaved: (() -> Void)?
    var onPlaybackSaved: ((String, Double) -> Void)?
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

    init(defaults: UserDefaults = .standard, usesOpenAI: Bool = ReaderBuild.isOpenAI, openAIService: OpenAINarrationService? = nil) {
        self.defaults = defaults
        self.injectedOpenAIService = openAIService
        cleanupProvider = NarrationProvider(rawValue: defaults.string(forKey: "narrationCleanupProvider") ?? "") ?? (usesOpenAI ? .openAI : .local)
        let selectedSpeech = NarrationProvider(rawValue: defaults.string(forKey: "narrationSpeechProvider") ?? "") ?? (usesOpenAI ? .openAI : .local)
        speechProvider = selectedSpeech
        modelPath = defaults.string(forKey: "narrationModels") ?? Self.runtimeRoot.appendingPathComponent("Models").path
        let fallbackVoice = selectedSpeech == .openAI ? "marin" : "af_heart"
        let savedVoice = defaults.string(forKey: selectedSpeech == .local ? "narrationLocalVoice" : "narrationOpenAIVoice") ?? defaults.string(forKey: "narrationVoice") ?? fallbackVoice
        voice = selectedSpeech == .openAI ? (OpenAINarrationOptions.voices.contains(savedVoice) ? savedVoice : fallbackVoice)
            : (Self.voices.contains { $0.id == savedVoice } ? savedVoice : fallbackVoice)
        let savedSpeed = defaults.object(forKey: "narrationSpeed") as? Double ?? 1
        speed = savedSpeed.isFinite ? min(1.5, max(0.6, savedSpeed)) : 1
        keepReferences = defaults.object(forKey: "narrationKeepReferences") as? Bool ?? false
        cleanText = defaults.object(forKey: "narrationCleanText") as? Bool ?? true
        super.init()
    }

    func resetGenerationDefaults() { cleanupProvider = .local; speechProvider = .local; voice = "af_heart"; speed = 1; cleanText = true; keepReferences = false }
    func isGenerating(_ itemID: String) -> Bool { isBusy && activeItemID == itemID }
    func playbackPosition(for item: ReaderItem) -> Double { playbackItemID == item.id ? position : (item.narration?.playbackPosition ?? 0) }
    func playbackDuration(for item: ReaderItem) -> Double { playbackItemID == item.id ? duration : (item.narration?.duration ?? 0) }
    static func time(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var runtimeDirectory: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("NarrationRuntime")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("runtime/bin/python3.11").path) { return bundled }
        return Self.runtimeRoot
    }
    var isReady: Bool {
        readinessIssue == nil
    }
    var readinessIssue: String? {
        if needsAPIKey && injectedOpenAIService == nil && (try? OpenAIKey.read()) == nil { return "Add an OpenAI API key in Settings." }
        if !FileManager.default.isExecutableFile(atPath: mp3Encoder.path) { return "Reader’s MP3 encoder is missing. Rebuild the app." }
        if cleanupProvider == .local || speechProvider == .local {
            if !FileManager.default.isExecutableFile(atPath: runtimeDirectory.appendingPathComponent("runtime/bin/python3.11").path) { return "The local narration runtime is missing. Run scripts/setup-narration.sh and rebuild Reader." }
        }
        for (needed, folder) in [(cleanupProvider == .local && cleanText, "cleanup"), (speechProvider == .local, "speech")] {
            if needed && !FileManager.default.fileExists(atPath: URL(fileURLWithPath: modelPath).appendingPathComponent(folder).path) { return "The local \(folder) model is missing. Locate its models folder in Settings." }
        }
        return nil
    }
    var hasAPIKey: Bool { (try? OpenAIKey.read()) != nil }
    @discardableResult func saveAPIKey(_ value: String) -> Bool {
        do { try ReaderAPIKeychain.save(value); keyStatus = "API key saved in macOS Keychain."; objectWillChange.send(); return true }
        catch { keyStatus = error.localizedDescription }
        objectWillChange.send()
        return false
    }
    func removeAPIKey() {
        do { try ReaderAPIKeychain.remove(); keyStatus = "Keychain key removed." }
        catch { keyStatus = error.localizedDescription }
        objectWillChange.send()
    }
    var mp3Encoder: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("NarrationRuntime/bin/ffmpeg")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return Self.runtimeRoot.appendingPathComponent("bin/ffmpeg")
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
        if usesOpenAI { generateOpenAI(item: item, store: store); return }
        errorItemID = item.id; error = nil
        guard isReady else { error = readinessIssue; return }
        guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "This document has no extracted text. Scanned PDFs need OCR before they can be narrated."; return }
        cancelled = false; outputBuffer = ""; errorTail = ""; workerError = nil; error = nil
        activeItemID = item.id; activeTitle = item.title; fraction = 0; phase = "Preparing text"; message = "Starting local text preparation…"
        let job = store.root.appendingPathComponent("Work/Narration-\(UUID().uuidString)")
        jobDirectory = job
        do {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            let input = job.appendingPathComponent("input.txt")
            try Data(item.text.utf8).write(to: input, options: .atomic)
            let request: [String: Any] = ["cleanupProvider": "local", "speechProvider": "local", "itemID": item.id, "title": item.title, "sourceURL": item.originalURL ?? "", "voice": voice, "speed": String(speed), "cleanText": cleanText, "keepReferences": keepReferences]
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
                Task { @MainActor in
                    guard let self, self.jobDirectory == job, self.isBusy else { return }
                    self.consume(data)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in if let self, self.jobDirectory == job, self.isBusy { self.errorTail = String((self.errorTail + String(decoding: data, as: UTF8.self)).suffix(12_000)) } }
            }
            let selectedVoice = voice, selectedSpeed = speed
            task.terminationHandler = { [weak self] task in
                Task { @MainActor in await self?.finish(status: task.terminationStatus, itemID: item.id, store: store, job: job, voice: selectedVoice, speed: selectedSpeed) }
            }
            process = task; isBusy = true
            try task.run()
        } catch {
            output?.fileHandleForReading.readabilityHandler = nil; errors?.fileHandleForReading.readabilityHandler = nil
            output = nil; errors = nil; process = nil; isBusy = false; activeItemID = nil; self.error = error.localizedDescription; phase = "Could not start"
        }
    }
    private func generateOpenAI(item: ReaderItem, store: LibraryStore) {
        errorItemID = item.id; error = nil
        let job = store.root.appendingPathComponent("Work/Narration-\(UUID().uuidString)")
        do {
            guard FileManager.default.isExecutableFile(atPath: mp3Encoder.path) else { throw LibraryError.io("Reader’s MP3 encoder is missing. Rebuild the OpenAI app.") }
            if let issue = readinessIssue { throw LibraryError.io(issue) }
            let service = try injectedOpenAIService ?? OpenAINarrationService(apiKey: needsAPIKey ? OpenAIKey.read() : "", encoder: mp3Encoder)
            let pdf = item.kind == .pdf ? try store.contentURL(for: item) : nil
            let options = OpenAINarrationOptions(voice: voice, speed: speed, cleanText: cleanText, keepReferences: keepReferences, cleanupProvider: cleanupProvider, speechProvider: speechProvider)
            let worker = ReaderResources.bundle.url(forResource: "narration_worker", withExtension: "py", subdirectory: "Resources/Narration")
            let local = worker.map { LocalNarrationStage(runtime: runtimeDirectory, models: URL(fileURLWithPath: modelPath), encoder: mp3Encoder, worker: $0) }
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
            try Data(item.text.utf8).write(to: job.appendingPathComponent("input.txt"), options: .atomic)
            let request: [String: Any] = ["cleanupProvider": cleanupProvider.rawValue, "speechProvider": speechProvider.rawValue, "itemID": item.id, "title": item.title, "voice": voice, "speed": speed, "cleanText": cleanText, "keepReferences": keepReferences]
            try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys]).write(to: job.appendingPathComponent("request.json"), options: .atomic)
            cancelled = false; workerError = nil; errorTail = ""; outputBuffer = ""
            jobDirectory = job; activeItemID = item.id; activeTitle = item.title; fraction = 0
            phase = "Preparing text"; message = "Starting narration with your selected services…"; isBusy = true
            openAITask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    _ = try await service.generate(item: item, pdf: pdf, job: job, options: options, local: local) { [weak self] progress in
                        await self?.apply(progress: progress, job: job)
                    }
                    await self?.finish(status: 0, itemID: item.id, store: store, job: job, voice: options.voice, speed: options.speed)
                } catch {
                    await self?.recordWorkerError(error.localizedDescription)
                    await self?.finish(status: 1, itemID: item.id, store: store, job: job, voice: options.voice, speed: options.speed)
                }
            }
        } catch { self.error = error.localizedDescription; phase = "Could not start" }
    }
    private func apply(progress: OpenAINarrationProgress, job: URL) {
        guard jobDirectory == job, isBusy else { return }
        phase = progress.phase; message = progress.message; fraction = max(fraction, progress.fraction)
    }
    private func recordWorkerError(_ message: String) { workerError = message }
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
        process = nil; output = nil; errors = nil; openAITask = nil
        defer {
            isBusy = false; activeItemID = nil
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
            jobDirectory = nil; errorItemID = nil; phase = "Narration saved"; fraction = 1; message = "MP3 and prepared text are saved in your library."
            if let note = metadata?["extractionNote"] as? String, note.localizedCaseInsensitiveContains("no readable text") { message += " " + note + ". Those pages need OCR for narration." }
            onSaved?()
        } catch {
            phase = "Audio needs recovery"
            self.error = "The generated audio is preserved at \(job.path), but could not be added to the library.\n\n\(error.localizedDescription)"
        }
    }
    func cancel() {
        if let openAITask { cancelled = true; message = "Cancelling OpenAI narration…"; openAITask.cancel(); return }
        guard let process, process.isRunning else { return }
        cancelled = true; message = "Cancelling the local narration…"; process.terminate()
    }
    func togglePlayback(item: ReaderItem, store: LibraryStore) {
        guard preparePlayback(item: item, store: store), let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false; timer?.invalidate(); timer = nil; savePlaybackPosition() }
        else {
            if position >= duration - 0.05 || player.currentTime >= player.duration - 0.05 { player.currentTime = 0; position = 0 }
            guard player.play() else { errorItemID = item.id; error = "The saved narration could not start playing."; return }
            isPlaying = true; startTimer()
        }
    }
    @discardableResult private func preparePlayback(item: ReaderItem, store: LibraryStore) -> Bool {
        let latest = (try? store.item(id: item.id)) ?? item
        if playbackItemID != item.id || playbackNarrationID != latest.narration?.id || player == nil {
            stopPlayback()
            do {
                guard let url = try store.narrationAudioURL(for: latest) else { return false }
                let next = try AVAudioPlayer(contentsOf: url); next.delegate = self
                guard next.prepareToPlay() else { throw LibraryError.io("The MP3 could not be decoded.") }
                let resume = min(latest.narration?.playbackPosition ?? 0, next.duration)
                next.currentTime = resume
                player = next; playbackStore = store; playbackItemID = item.id; playbackNarrationID = latest.narration?.id; duration = next.duration; position = resume
                if errorItemID == item.id { error = nil; errorItemID = nil }
            } catch { errorItemID = item.id; self.error = "The saved narration could not be opened: " + error.localizedDescription; return false }
        }
        return true
    }
    func seek(_ seconds: Double, item: ReaderItem, store: LibraryStore) {
        guard preparePlayback(item: item, store: store) else { return }
        seek(seconds)
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, player != nil else { return }
        position = max(0, min(seconds, duration)); player?.currentTime = position; savePlaybackPosition(seconds: position)
    }
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
    func savePlaybackPosition(seconds: Double? = nil) {
        guard let id = playbackItemID, let player, let store = playbackStore else { return }
        let saved = seconds ?? (!isPlaying && position >= duration - 0.05 ? duration : player.currentTime)
        do {
            try store.saveNarrationPosition(itemID: id, seconds: saved); lastPositionSave = Date()
            onPlaybackSaved?(id, saved)
        }
        catch { errorItemID = id; self.error = "Audio playback position could not be saved: " + error.localizedDescription }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.isPlaying = false; self.position = self.duration; self.savePlaybackPosition(seconds: self.duration); self.timer?.invalidate(); self.timer = nil
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
