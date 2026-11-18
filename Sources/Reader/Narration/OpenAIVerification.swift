import Foundation
import AppKit
import AVFoundation
import ReaderCore

private actor OpenAIFixture {
    var calls: [URLRequest] = []
    var status = 200
    var mode = "valid"
    func set(status: Int = 200, mode: String = "valid") { self.status = status; self.mode = mode }
    func count() -> Int { calls.count }
    func requests() -> [URLRequest] { calls }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        try await Task.sleep(nanoseconds: mode == "slow" ? 2_000_000_000 : 60_000_000)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let path = request.url!.path
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": path.hasSuffix("speech") ? "application/octet-stream" : "application/json", "x-request-id": "req_reader_fixture"])!
        if status != 200 { return (Data("{\"error\":\"sensitive echoed error body\"}".utf8), response) }
        if path.hasSuffix("speech") {
            if mode == "invalidAudio" { return (Data([1, 2, 3]), response) }
            // A decodable half-second tone verifies encoding and native playback.
            var data = Data()
            for index in 0..<12_000 {
                var sample = Int16(sin(Double(index) * 2 * .pi * 220 / 24_000) * 2_000).littleEndian
                withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            }
            return (data, response)
        }
        let source = try JSONDecoder().decode([OpenAITextUnit].self, from: Data((body["input"] as! String).utf8))
        let decisions = source.map { unit in
            OpenAITextDecision(id: unit.id, kind: unit.raw.hasPrefix("Subscribe") ? "boilerplate" : unit.raw.hasPrefix("References") || unit.raw.hasPrefix("Smith,") ? "reference" : "body", citations: unit.raw.contains("[12]") ? ["[12]"] : [])
        }
        let plan = ["units": try JSONSerialization.jsonObject(with: JSONEncoder().encode(decisions))]
        var object: [String: Any] = ["id": "resp_reader_fixture", "model": OpenAINarrationOptions.cleanupModel, "status": mode == "incomplete" ? "incomplete" : "completed", "usage": ["input_tokens": 120, "output_tokens": 50, "input_tokens_details": ["cached_tokens": 20]], "output": [["type": "message", "content": [["type": "output_text", "text": String(decoding: try JSONSerialization.data(withJSONObject: plan), as: UTF8.self)]]]]]
        if mode == "refusal" { object["output"] = [["type": "message", "content": [["type": "refusal", "refusal": "Not available"]]]] }
        if mode == "malformed" { return (Data("{}".utf8), response) }
        return (try JSONSerialization.data(withJSONObject: object), response)
    }
}

private actor OpenAISpeechFixture: OpenAISpeechConnection {
    let request: URLRequest
    let mode: String
    var outgoing: [[String: Any]] = []
    var events: [[String: Any]] = [["type": "session.created"]]
    init(request: URLRequest, mode: String = "valid") { self.request = request; self.mode = mode }
    func send(_ data: Data) async throws {
        let event = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        outgoing.append(event)
        if event["type"] as? String == "session.update" { events.append(["type": "session.updated"]) }
        else {
            let response = event["response"] as! [String: Any]
            let input = response["input"] as! [[String: Any]]
            let text = ((input[0]["content"] as! [[String: Any]])[0]["text"] as! String).replacingOccurrences(of: "Read this passage verbatim:\n\n", with: "")
            var pcm = Data()
            for index in 0..<12_000 {
                var sample = Int16(sin(Double(index) * 2 * .pi * 220 / 24_000) * 2_000).littleEndian
                withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            }
            if mode == "error" { events.append(["type": "error", "error": ["code": "rate_limit_exceeded", "message": "sensitive error detail"]]); return }
            events += [["type": "response.output_audio.delta", "delta": mode == "badAudio" ? "bad base64" : pcm.base64EncodedString()],
                       ["type": "response.output_audio_transcript.done", "transcript": mode == "unfaithful" ? "Here is a short summary." : text],
                       ["type": "response.done", "response": ["id": "resp_speech_fixture", "status": mode == "incomplete" ? "incomplete" : "completed", "usage": ["input_tokens": 80, "output_tokens": 100]]]]
        }
    }
    func receive() async throws -> Data {
        try await Task.sleep(nanoseconds: 10_000_000)
        guard !events.isEmpty else { throw LibraryError.io("Mock audio stream disconnected") }
        return try JSONSerialization.data(withJSONObject: events.removeFirst())
    }
    func sent() -> [[String: Any]] { outgoing }
    nonisolated func close() { }
}

@MainActor enum OpenAIVerification {
    static func runProviders(live: Bool) async -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ReaderProviders\(live ? "Live" : "Mocked")-\(UUID().uuidString)")
        let suite = "Reader.Providers.\(UUID().uuidString)", keyService = "au.pcarroll.Reader.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ condition: Bool, _ text: String) throws {
            guard condition else { throw LibraryError.io("Provider verification failed: " + text) }
            count += 1; print("PASS: " + text); fflush(stdout)
        }
        func wait(_ controller: NarrationController) async throws {
            let deadline = Date().addingTimeInterval(360)
            while controller.isBusy {
                if Date() > deadline { controller.cancel(); throw LibraryError.io("Provider verification timed out") }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        do {
            defaults.set("bf_emma", forKey: "narrationVoice")
            let fixture = OpenAIFixture()
            let encoder = NarrationController(defaults: defaults, usesOpenAI: false).mp3Encoder
            let fake = OpenAINarrationService(apiKey: "synthetic-provider-key", encoder: encoder, transport: { try await fixture.send($0) }, speechConnect: { OpenAISpeechFixture(request: $0) })
            let narrator = NarrationController(defaults: defaults, usesOpenAI: false, openAIService: live ? nil : fake)
            try check(narrator.voice == "bf_emma" && narrator.cleanupProvider == .local && narrator.speechProvider == .local, "Existing local preferences migrate without changing the selected voice")
            narrator.speechProvider = .openAI; narrator.voice = "cedar"
            narrator.speechProvider = .local
            try check(narrator.voice == "bf_emma", "Switching back to local audio restores the previous local voice")
            narrator.speechProvider = .openAI
            try check(narrator.voice == "cedar", "Switching back to API audio restores the previous API voice")
            narrator.cleanupProvider = .local
            let restoredSettings = NarrationController(defaults: defaults, usesOpenAI: false)
            try check(restoredSettings.cleanupProvider == .local && restoredSettings.speechProvider == .openAI && restoredSettings.voice == "cedar", "Independent providers and per-provider voices persist across controllers")
            if !live {
                let dummy = "sk-proj-reader-synthetic-keychain-\(UUID().uuidString)"
                try ReaderAPIKeychain.save(dummy, service: keyService)
                defer { try? ReaderAPIKeychain.remove(service: keyService) }
                try check(ReaderAPIKeychain.read(service: keyService) == dummy, "Settings credential storage round-trips through macOS Keychain using an isolated synthetic key")
                try ReaderAPIKeychain.remove(service: keyService)
                try check(ReaderAPIKeychain.read(service: keyService) == nil, "Removing the isolated Keychain credential leaves no saved test key")
            }
            let model = AppModel(narrationController: narrator)
            model.openLibrary(root, create: true)
            guard let store = model.store else { throw LibraryError.io(model.libraryError ?? "Provider library missing") }
            defer { narrator.cancel(); narrator.stopPlayback(); store.close() }
            let source = root.appendingPathComponent("Work/Import")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            let text = """
            A quiet reading practice

            Subscribe now for weekly promotions.

            Reading can slow the pace of a day. A saved passage lets us return to an idea with fresh attention. The last sentence stays with the original reading.

            References

            Smith, A. (2020). An example reference.
            """
            try Data("<article><p>\(text)</p></article>".utf8).write(to: source.appendingPathComponent("article.html"))
            for cleanup in NarrationProvider.allCases { for speech in NarrationProvider.allCases {
                let label = "\(cleanup.rawValue) cleanup / \(speech.rawValue) audio"
                let item = ReaderItem(title: label, kind: .article, contentPath: "article.html", text: text)
                try store.addItem(item, from: source); try model.refresh(); model.select(item.id)
                narrator.cleanupProvider = cleanup; narrator.speechProvider = speech
                narrator.voice = speech == .local ? "af_heart" : "marin"
                narrator.cleanText = true; narrator.keepReferences = false
                let before = await fixture.count()
                model.performNarrationAction()
                try check(narrator.isGenerating(item.id) && !model.showNarration, "\(label) starts in the background")
                try await wait(narrator)
                guard let saved = try store.item(id: item.id), let audio = try store.narrationAudioURL(for: saved), let script = try store.narrationScriptURL(for: saved) else { throw LibraryError.io(narrator.error ?? "Missing provider result: " + label) }
                let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: script.deletingLastPathComponent().appendingPathComponent("metadata.json"))) as! [String: Any]
                let prepared = try String(contentsOf: script, encoding: .utf8)
                try check(prepared.contains("The last sentence stays with the original reading.") && !prepared.contains("Smith, A."), "\(label) preserves body text and the selected reference setting")
                try check(metadata["cleanupProvider"] as? String == cleanup.rawValue && metadata["speechProvider"] as? String == speech.rawValue, "\(label) records the actual selected stages")
                try check(metadata["engine"] as? String == (speech == .local ? "Kokoro-82M" : OpenAINarrationOptions.speechModel), "\(label) uses the selected speech engine")
                try check((metadata["cleanupEngine"] as? String ?? "").contains(cleanup == .local ? "DeBERTa" : OpenAINarrationOptions.cleanupModel), "\(label) uses the selected cleanup engine")
                let player = try AVAudioPlayer(contentsOf: audio)
                try check(player.duration > 0.1 && abs(player.duration - (saved.narration?.duration ?? 0)) < 0.3 && model.narrationActionTitle == "Play narration", "\(label) produces a decodable managed MP3 and Play action")
                if !live {
                    let after = await fixture.count()
                    try check((after > before) == (cleanup == .openAI), "\(label) calls the cleanup API only when chosen")
                }
                narrator.seek(1, item: saved, store: store); narrator.stopPlayback()
            } }
            let fixturePDF = URL(fileURLWithPath: ProcessInfo.processInfo.environment["READER_FIXTURE_PDF"] ?? fm.currentDirectoryPath + "/Tests/Fixtures/reading-fixture.pdf")
            let pdfImport = try await ArticleImporter().preparePDF(fileURL: fixturePDF)
            defer { pdfImport.cleanup() }
            for cleanup in NarrationProvider.allCases {
                let speech: NarrationProvider = cleanup == .local ? .openAI : .local
                let item = ReaderItem(title: "Mixed PDF \(cleanup.rawValue)", kind: .pdf, contentPath: pdfImport.contentPath, text: pdfImport.text)
                try store.addItem(item, from: pdfImport.directory)
                let pdfURL = try store.contentURL(for: item)
                let before = try OpenAINarrationService.digest(Data(contentsOf: pdfURL))
                narrator.cleanupProvider = cleanup; narrator.speechProvider = speech
                narrator.generate(item: item, store: store); try await wait(narrator)
                guard let saved = try store.item(id: item.id), let scriptURL = try store.narrationScriptURL(for: saved) else { throw LibraryError.io(narrator.error ?? "Mixed PDF result missing") }
                let script = try String(contentsOf: scriptURL, encoding: .utf8)
                try check(script.contains("persimmon-1") && script.contains("persimmon-2") && script.contains("persimmon-3"), "Mixed PDF \(cleanup.rawValue) cleanup retains all normal/rotated pages")
                try check(before == OpenAINarrationService.digest(Data(contentsOf: pdfURL)), "Mixed PDF \(cleanup.rawValue) cleanup preserves source bytes")
            }
            try check(try store.items().allSatisfy { $0.narration != nil }, "All four article routes and both mixed PDF routes retain completed recordings")
            print("PROVIDERS \(live ? "LIVE" : "MOCKED-API/REAL-LOCAL") VERIFICATION PASSED: \(count) checks. Temporary library: \(root.path)"); fflush(stdout)
            return true
        } catch {
            print("PROVIDERS VERIFICATION FAILED: \(error.localizedDescription)\nTemporary library: \(root.path)"); fflush(stdout)
            return false
        }
    }

    static func run(live: Bool) async -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ReaderOpenAI\(live ? "Live" : "Fixture")-\(UUID().uuidString)")
        let suite = "Reader.OpenAIVerification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LibraryError.io("Verification failed: " + message) }
            count += 1; print("PASS: " + message); fflush(stdout)
        }
        func wait(_ controller: NarrationController) async throws {
            let deadline = Date().addingTimeInterval(360)
            while controller.isBusy {
                if Date() > deadline { controller.cancel(); throw LibraryError.io("OpenAI verification timed out.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        func rejects(_ operation: () async throws -> Void, _ message: String) async throws {
            do { try await operation() } catch { try check(true, message); return }
            try check(false, message)
        }
        do {
            let fixture = OpenAIFixture()
            let encoder = NarrationController(defaults: defaults, usesOpenAI: false).mp3Encoder
            let service = OpenAINarrationService(apiKey: "reader-test-secret-never-log", encoder: encoder, transport: { request in try await fixture.send(request) }, speechConnect: { OpenAISpeechFixture(request: $0) })
            let controller = NarrationController(defaults: defaults, usesOpenAI: true, openAIService: live ? nil : service)
            let model = AppModel(narrationController: controller)
            model.openLibrary(root, create: true)
            guard let store = model.store else { throw LibraryError.io(model.libraryError ?? "Could not open isolated library") }
            defer { controller.cancel(); controller.stopPlayback(); store.close() }
            try check(controller.isReady && controller.voice == "marin", "OpenAI path is ready without a local inference runtime or model check")
            controller.speed = 1.1; controller.cleanText = true; controller.keepReferences = false
            let restoredSettings = NarrationController(defaults: defaults, usesOpenAI: true)
            try check(restoredSettings.voice == "marin" && restoredSettings.speed == 1.1 && restoredSettings.cleanText && !restoredSettings.keepReferences, "OpenAI voice, speed and cleanup defaults persist")
            let text = """
            Reading as a conversation

            Subscribe now to receive our weekly promotions.

            A quiet paragraph can change the pace of a day. Reading is a conversation between the words on a page and the attention we bring to them. [12]

            A saved recording lets us return to an idea while walking, then revisit the exact passage with a pencil in hand. Neither practice needs to replace the other.

            References

            Smith, A. (2020). An example reference used only for this original test.
            """
            let staged = root.appendingPathComponent("Work/Import")
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            try Data("<article><p>Original Reader OpenAI comparison fixture.</p></article>".utf8).write(to: staged.appendingPathComponent("article.html"))
            let article = ReaderItem(title: "Reading as a conversation", kind: .article, contentPath: "article.html", text: text)
            let other = ReaderItem(title: "A second reading", kind: .article, contentPath: "article.html", text: "A second saved article.")
            try store.addItem(article, from: staged); try store.addItem(other, from: staged)
            try model.refresh(); model.select(article.id)
            let sourceHash = try OpenAINarrationService.digest(Data(contentsOf: store.contentURL(for: article)))
            model.performNarrationAction()
            try check(controller.isBusy && controller.activeItemID == article.id && !model.showNarration, "Create launches the native OpenAI task with inline state and no modal")
            model.select(other.id)
            try check(model.selectedID == other.id && controller.isGenerating(article.id), "Reading another document remains available during OpenAI generation")
            controller.speed = 1.4
            try await wait(controller)
            guard let saved = try store.item(id: article.id), let record = saved.narration,
                  let audio = try store.narrationAudioURL(for: saved), let scriptURL = try store.narrationScriptURL(for: saved) else { throw LibraryError.io(controller.error ?? "No OpenAI narration saved") }
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            try check(script.contains("A quiet paragraph can change the pace of a day.") && script.contains("Neither practice needs to replace the other."), "Cleanup preserves original body prose and its final passage")
            try check(!script.contains("Subscribe now") && !script.contains("Smith, A.") && !script.contains("[12]"), "OpenAI cleanup removes boilerplate, references and inline citations")
            try check(record.voice == "marin" && record.speed == 1.1, "The running job captures defaults before later Settings edits")
            let decoded = try AVAudioPlayer(contentsOf: audio)
            try check(decoded.duration > 0.1 && abs(decoded.duration - (record.duration ?? 0)) < 0.3, "The complete MP3 decodes with a matching duration")
            let metadataURL = scriptURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
            try check(metadata["engine"] as? String == OpenAINarrationOptions.speechModel && metadata["cleanupEngine"] as? String == OpenAINarrationOptions.cleanupModel && metadata["responseStorage"] as? Bool == false, "Saved provenance identifies both OpenAI models and stateless cleanup")
            model.select(article.id)
            try check(model.narrationActionTitle == "Play narration", "Completion replaces Create with Play narration")
            let beforePlay = await fixture.count()
            let resume = min(0.2, decoded.duration / 2)
            controller.seek(resume, item: saved, store: store)
            try check(!controller.isPlaying && abs(controller.position - resume) < 0.05, "The inline seek bar can position saved OpenAI audio before Play")
            model.performNarrationAction(); controller.togglePlayback(item: saved, store: store)
            let afterPlay = await fixture.count()
            try check(!controller.isPlaying && !controller.isBusy && beforePlay == afterPlay, "Play/Pause uses the saved MP3 without an API request")
            let audioHash = try OpenAINarrationService.digest(Data(contentsOf: audio))
            try check(sourceHash == OpenAINarrationService.digest(Data(contentsOf: store.contentURL(for: article))), "OpenAI generation leaves the original article bytes unchanged")

            if !live {
                let requests = await fixture.requests()
                let cleanupRequest = requests.first { $0.url?.path == "/v1/responses" }!
                let body = try JSONSerialization.jsonObject(with: cleanupRequest.httpBody!) as! [String: Any]
                let textFormat = (body["text"] as! [String: Any])["format"] as! [String: Any]
                try check(cleanupRequest.value(forHTTPHeaderField: "Authorization") == "Bearer reader-test-secret-never-log" && cleanupRequest.url?.host == "api.openai.com", "The credential is sent only as an OpenAI Authorization header")
                try check(body["store"] as? Bool == false && body["truncation"] as? String == "disabled" && textFormat["strict"] as? Bool == true, "Cleanup requests enforce stateless complete structured output")
                try check(body["model"] as? String == OpenAINarrationOptions.cleanupModel && body["service_tier"] as? String == "default" && body["prompt_cache_key"] as? String == "reader-cleanup-v1", "Cleanup uses the selected efficient model, standard tier and stable prefix key")
                let speechRequest = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime")!)
                let socket = OpenAISpeechFixture(request: speechRequest)
                let speechOptions = OpenAINarrationOptions(voice: "marin", speed: 1.1, cleanText: true, keepReferences: false)
                let (_, receipt) = try await OpenAIRealtimeSpeech.generate(text: "A complete original passage.", apiKey: "fixture", options: speechOptions, connect: { _ in socket })
                let sent = await socket.sent()
                let session = sent[0]["session"] as! [String: Any]
                let output = (session["audio"] as! [String: Any])["output"] as! [String: Any]
                let response = sent[1]["response"] as! [String: Any]
                try check(output["voice"] as? String == "marin" && output["speed"] as? Double == 1.1 && receipt["model"] as? String == OpenAINarrationOptions.speechModel && response["conversation"] as? String == "none", "Realtime speech uses captured voice/speed, PCM and an isolated response")
                for mode in ["badAudio", "incomplete", "unfaithful", "error"] {
                    try await rejects({ _ = try await OpenAIRealtimeSpeech.generate(text: "A complete original passage.", apiKey: "fixture", options: speechOptions, connect: { OpenAISpeechFixture(request: $0, mode: mode) }) }, "\(mode.capitalized) audio streams are rejected without publishing an MP3")
                }
                try check(OpenAIRealtimeSpeech.faithful(source: "Exact words, in order.", transcript: "Exact words in order!") && !OpenAIRealtimeSpeech.faithful(source: "The opening sentence. A middle section. The final conclusion.", transcript: "The opening sentence."), "Spoken transcript validation tolerates punctuation and rejects truncation")
                let units = [OpenAITextUnit(id: 0, raw: "Body 🙂 [12]."), OpenAITextUnit(id: 1, raw: "Subscribe now"), OpenAITextUnit(id: 2, raw: "Smith, A.")]
                let decisions = [OpenAITextDecision(id: 0, kind: "body", citations: ["[12]"]), .init(id: 1, kind: "boilerplate", citations: []), .init(id: 2, kind: "reference", citations: [])]
                for clean in [true, false] { for references in [true, false] {
                    let rendered = try OpenAINarrationService.render(units: units, decisions: decisions, options: .init(voice: "marin", speed: 1, cleanText: clean, keepReferences: references))
                    try check(rendered.contains("Subscribe") == !clean && rendered.contains("Smith") == references && rendered.contains("[12]") == references && rendered.contains("🙂"), "Cleanup/reference switches are independent (cleanup \(clean), references \(references))")
                } }
                try await rejects({ _ = try OpenAINarrationService.render(units: units, decisions: Array(decisions.dropLast()), options: .init(voice: "marin", speed: 1, cleanText: true, keepReferences: false)) }, "Missing source decisions are rejected")
                try await rejects({ _ = try OpenAINarrationService.render(units: units, decisions: [decisions[0], decisions[0], decisions[2]], options: .init(voice: "marin", speed: 1, cleanText: true, keepReferences: false)) }, "Duplicate source decisions are rejected")
                try await rejects({ _ = try OpenAINarrationService.render(units: [units[0]], decisions: [.init(id: 0, kind: "body", citations: ["invented content"])], options: .init(voice: "marin", speed: 1, cleanText: true, keepReferences: false)) }, "Invented citation edits cannot remove author prose")
                let safeBody = try OpenAINarrationService.render(units: [units[0]], decisions: [.init(id: 0, kind: "body", citations: ["Body 🙂"])], options: .init(voice: "marin", speed: 1, cleanText: true, keepReferences: false))
                try check(safeBody.contains("Body 🙂"), "An exact source match cannot delete ordinary prose disguised as a citation")
                let long = String(repeating: "A long sentence 🙂 with a citation [12].\n", count: 600)
                let chunks = OpenAINarrationService.chunks(long, maximumBytes: 1_800)
                try check(chunks.joined() == long && chunks.allSatisfy { $0.utf8.count <= 1_800 }, "Long Unicode speech chunks preserve every character within request limits")
                for status in [401, 403, 429, 500] {
                    await fixture.set(status: status)
                    do { _ = try await service.cleanup(units: units); try check(false, "HTTP error should fail") }
                    catch { try check(!error.localizedDescription.contains("sensitive echoed") && !error.localizedDescription.contains("reader-test-secret"), "HTTP \(status) produces a safe actionable error without echoing credentials/body") }
                }
                for mode in ["incomplete", "refusal", "malformed"] {
                    await fixture.set(mode: mode)
                    try await rejects({ _ = try await service.cleanup(units: units) }, "\(mode.capitalized) cleanup is rejected without synthesizing partial text")
                }
                await fixture.set(status: 429)
                controller.generate(item: saved, store: store); try await wait(controller)
                try check(controller.error != nil && (try store.item(id: article.id))?.narration?.id == record.id, "Failed API replacement preserves the completed database record")
                await fixture.set(mode: "slow")
                controller.generate(item: saved, store: store); controller.cancel(); try await wait(controller)
                try check(controller.phase == "Cancelled" && (try store.item(id: article.id))?.narration?.id == record.id, "Cancelling a network job preserves the previous narration")
                try check(audioHash == OpenAINarrationService.digest(Data(contentsOf: audio)), "Failed/cancelled jobs preserve previous MP3 bytes")
                await fixture.set()
                let keyFixture = root.appendingPathComponent("test.env")
                try Data("OTHER=ignore\nexport OPENAI_API_KEY='synthetic-test-key'\n".utf8).write(to: keyFixture)
                try check(try OpenAIKey.read(file: keyFixture, environment: [:]) == "synthetic-test-key", "Local key loading parses the confirmed file without shell evaluation")
                let durable = try fm.contentsOfDirectory(at: scriptURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                try check(try durable.allSatisfy { !(try Data(contentsOf: $0)).contains(Data("reader-test-secret-never-log".utf8)) }, "Saved narration artifacts never contain the API key")
                try check((metadata["requests"] as? [[String: Any]])?.contains(where: { ($0["usage"] as? [String: Any])?["input_tokens"] as? Int == 120 }) == true, "Input, output and cached-token usage receipts remain with the recording")
            }

            let fixturePDF = URL(fileURLWithPath: ProcessInfo.processInfo.environment["READER_FIXTURE_PDF"] ?? fm.currentDirectoryPath + "/Tests/Fixtures/reading-fixture.pdf")
            let prepared = try await ArticleImporter().preparePDF(fileURL: fixturePDF)
            defer { prepared.cleanup() }
            let pdf = ReaderItem(title: "OpenAI PDF comparison", kind: .pdf, contentPath: prepared.contentPath, text: prepared.text)
            try store.addItem(pdf, from: prepared.directory)
            let managedPDF = try store.contentURL(for: pdf)
            let pdfHash = try OpenAINarrationService.digest(Data(contentsOf: managedPDF))
            let extracted = try OpenAINarrationService.extract(item: pdf, pdf: managedPDF).0
            try check(extracted.contains("persimmon-1") && extracted.contains("persimmon-2") && extracted.contains("persimmon-3"), "Native PDF extraction includes all normal/rotated source pages")
            controller.speed = 1; controller.generate(item: pdf, store: store); try await wait(controller)
            guard let savedPDF = try store.item(id: pdf.id), let pdfScript = try store.narrationScriptURL(for: savedPDF) else { throw LibraryError.io(controller.error ?? "PDF narration missing") }
            let pdfText = try String(contentsOf: pdfScript, encoding: .utf8)
            try check(pdfText.contains("persimmon-1") && pdfText.contains("persimmon-2") && pdfText.contains("persimmon-3"), "OpenAI PDF narration retains text from all three source pages")
            try check(pdfHash == OpenAINarrationService.digest(Data(contentsOf: managedPDF)), "PDF source bytes remain intact after OpenAI narration")
            controller.stopPlayback(); store.close()
            let reopened = try LibraryStore(root: root)
            defer { reopened.close() }
            guard let reopenedItem = try reopened.item(id: article.id) else { throw LibraryError.io("Article missing after reopen") }
            let offlinePlayer = NarrationController(defaults: defaults, usesOpenAI: true)
            offlinePlayer.seek(resume, item: reopenedItem, store: reopened)
            try check(abs(offlinePlayer.position - resume) < 0.05 && offlinePlayer.duration > 0, "A fresh player opens saved audio and seek position without any API request")
            offlinePlayer.stopPlayback()
            let snapshot = root.deletingLastPathComponent().appendingPathComponent("ReaderOpenAISnapshot-\(UUID().uuidString)")
            let restored = root.deletingLastPathComponent().appendingPathComponent("ReaderOpenAIRestored-\(UUID().uuidString)")
            try reopened.exportLibrary(to: snapshot); try LibraryStore.restore(from: snapshot, to: restored)
            let copy = try LibraryStore(root: restored); defer { copy.close() }
            let copyItem = try copy.item(id: article.id)!
            try check(try OpenAINarrationService.digest(Data(contentsOf: copy.narrationAudioURL(for: copyItem)!)) == audioHash, "Complete export and restore retain the OpenAI MP3 byte for byte")
            print("OPENAI \(live ? "LIVE" : "MOCKED") VERIFICATION PASSED: \(count) checks. Temporary library: \(root.path)"); fflush(stdout)
            return true
        } catch {
            print("OPENAI VERIFICATION FAILED: \(error.localizedDescription)\nTemporary library: \(root.path)"); fflush(stdout)
            return false
        }
    }
}
