import Foundation
import AppKit
import AVFoundation
import ReaderCore

/// Actual offline inference through the app controller. Every document/output is
/// in a new temporary library. No model, voice or speed preference is changed.
@MainActor enum NarrationVerification {
    static func run() async -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ReaderNarrationVerification-\(UUID().uuidString)")
        let fixturePath = ProcessInfo.processInfo.environment["READER_FIXTURE_PDF"]
            ?? URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/reading-fixture.pdf").path
        let fixture = URL(fileURLWithPath: fixturePath)
        var count = 0
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw LibraryError.invalid("Verification failed: \(description)") }
            count += 1; print("PASS: \(description)"); fflush(stdout)
        }
        func required<T>(_ value: T?, _ description: String) throws -> T {
            guard let value else { throw LibraryError.invalid(description) }; return value
        }
        func hash(_ url: URL) throws -> String { ArticleImporter.hash(try Data(contentsOf: url)) }
        func dictionary(_ url: URL) throws -> [String: Any] {
            try required(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "Invalid narration JSON")
        }
        func wait(_ controller: NarrationController, seconds: Double = 240) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            var previous = ""
            while controller.isBusy {
                if Date() > deadline { controller.cancel(); throw LibraryError.io("Narration verification timed out after \(Int(seconds)) seconds.") }
                if controller.phase != previous { previous = controller.phase; print("NARRATION: \(controller.phase)"); fflush(stdout) }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        do {
            let suiteName = "Reader.NarrationVerification.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let controller = NarrationController(defaults: defaults, usesOpenAI: false)
            let model = AppModel(narrationController: controller)
            model.openLibrary(root, create: true)
            let store = try required(model.store, model.libraryError ?? "Temporary narration library did not open")
            let narrator = model.narrator
            defer { narrator.cancel(); narrator.stopPlayback(); store.close() }
            try check(narrator.isReady, "Reader-owned local inference runtime and model copies are ready")
            narrator.voice = "af_bella"; narrator.speed = 1.2; narrator.cleanText = false; narrator.keepReferences = true
            let restoredSettings = NarrationController(defaults: defaults, usesOpenAI: false)
            try check(restoredSettings.voice == "af_bella" && restoredSettings.speed == 1.2 && !restoredSettings.cleanText && restoredSettings.keepReferences,
                      "Voice, speed, cleanup and reference defaults persist in Settings")
            narrator.resetGenerationDefaults()
            let fixtureText = """
            A quiet reading practice

            By Reader Test Author

            Subscriptions: click here

            Introduction

            Reading begins with attention. A useful passage can become a conversation. Reader keeps the original document and prepares a separate listening copy.

            References

            Smith, A. 2020. A book about reading.
            """
            let staged = root.appendingPathComponent("Work/FixtureImport")
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            let escaped = fixtureText.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            try Data("<!doctype html><meta charset=utf-8><article><pre>\(escaped)</pre></article>".utf8).write(to: staged.appendingPathComponent("article.html"), options: .atomic)
            let article = ReaderItem(title: "A quiet reading practice", kind: .article,
                                     originalURL: "https://example.com/reader-narration-fixture", contentPath: "article.html", text: fixtureText)
            try store.addItem(article, from: staged)
            let otherArticle = ReaderItem(title: "Another paper to read", kind: .article, contentPath: "article.html", text: fixtureText)
            try store.addItem(otherArticle, from: staged)
            try model.refresh(); model.select(article.id)
            let managedArticle = try store.contentURL(for: article)
            let articleHash = try hash(managedArticle)
            try check(model.narrationActionTitle == "Create narration" && model.canPerformNarrationAction,
                      "An unnarrated document offers the one-click Create narration action")
            model.performNarrationAction()
            try check(narrator.isBusy, "Native controller launches asynchronous article narration")
            try check(narrator.activeItemID == article.id && model.narrationActionTitle == "Generating narration…" && !model.showNarration,
                      "Create narration starts inline progress without a modal panel")
            let readingProgress = ReadingProgress(fraction: 0.37)
            model.progress(id: article.id, value: readingProgress)
            let backgroundNote = ReaderAnnotation(itemID: article.id, note: "Written while narration runs in the background")
            model.addAnnotation(backgroundNote)
            model.select(otherArticle.id)
            try check(model.selectedID == otherArticle.id && narrator.isGenerating(article.id) && !narrator.isGenerating(otherArticle.id),
                      "The reader can change documents while progress remains attached to the generating article")
            try check(!model.canPerformNarrationAction && model.narrationActionTitle == "Create narration",
                      "Another unsaved document does not inherit the first article's generation state")
            model.select(article.id)
            narrator.voice = "af_bella"; narrator.speed = 1.3; narrator.cleanText = false; narrator.keepReferences = true
            try await wait(narrator)
            let narratedArticle = try required(try store.item(id: article.id), "Narrated article missing")
            let articleRecord = try required(narratedArticle.narration, narrator.error ?? "Article narration produced no committed result")
            try check(model.items.first(where: { $0.id == article.id })?.narration?.id == articleRecord.id,
                      "Narration completion callback refreshes the actual library model")
            let articleAudio = try required(try store.narrationAudioURL(for: narratedArticle), "Article MP3 missing")
            let articleScript = try required(try store.narrationScriptURL(for: narratedArticle), "Article script missing")
            let articleDirectory = articleAudio.deletingLastPathComponent()
            try check(model.narrationActionTitle == "Play narration" && !narrator.isBusy && narrator.activeItemID == nil && !model.showNarration,
                      "Completion replaces inline generation with Play narration automatically")
            let request = try dictionary(articleDirectory.appendingPathComponent("request.json"))
            try check(articleRecord.voice == "af_heart" && articleRecord.speed == 1 && request["cleanText"] as? Bool == true && request["keepReferences"] as? Bool == false,
                      "Changing Settings during generation does not alter the running job's defaults")
            try check((try store.item(id: article.id)?.progress) == readingProgress && (try store.annotations(itemID: article.id)).contains(where: { $0.id == backgroundNote.id && $0.note == backgroundNote.note }),
                      "Reading position and notes written during generation survive the narration commit")
            narrator.resetGenerationDefaults()
            try check(articleAudio.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/Items/"), "Completed MP3 is managed inside the configured library")
            let decoded = try AVAudioPlayer(contentsOf: articleAudio)
            try check(decoded.duration > 2 && decoded.prepareToPlay(), "AVAudioPlayer decodes the generated article MP3")
            let script = try String(contentsOf: articleScript, encoding: .utf8)
            try check(!script.localizedCaseInsensitiveContains("Subscriptions: click here")
                && !script.contains("Smith, A. 2020"), "Local cleanup removes publisher boilerplate and the reference entry")
            try check(script.contains("Reading begins with attention") && script.contains("Reader Test Author"),
                      "Prepared listening script preserves the author and body prose")
            let articleMetadata = try dictionary(articleDirectory.appendingPathComponent("metadata.json"))
            try check((articleMetadata["classifierCount"] as? Int ?? 0) >= 1
                && articleMetadata["engine"] as? String == "Kokoro-82M"
                && fm.fileExists(atPath: articleDirectory.appendingPathComponent("plan.json").path),
                      "Generated audio retains the real classifier, speech and reversible-plan provenance")
            try check(try hash(managedArticle) == articleHash, "Article narration leaves the saved original content unchanged")

            // Exercise real player loading and position persistence, including a
            // stale item snapshot, without prolonged audible playback.
            let resumeAt = min(2.0, max(0.5, decoded.duration / 4))
            narrator.seek(resumeAt, item: narratedArticle, store: store)
            try check(!narrator.isPlaying && abs(narrator.position - resumeAt) < 0.2,
                      "The inline seek bar can set a saved position before pressing Play")
            model.performNarrationAction()
            try check(narrator.isPlaying && !narrator.isBusy && narrator.jobDirectory == nil && (try store.item(id: article.id)?.narration?.id) == articleRecord.id,
                      "Play narration reuses the saved MP3 without starting another generation")
            model.performNarrationAction()
            try check(!narrator.isPlaying && model.narrationActionTitle == "Play narration", "The primary action toggles Play and Pause")
            narrator.seek(resumeAt); narrator.stopPlayback()
            try check(abs((model.items.first(where: { $0.id == article.id })?.narration?.playbackPosition ?? -1) - resumeAt) < 0.2,
                      "The document's seek bar retains its latest position when the player unloads")
            let savedPosition = try required(try store.item(id: article.id)?.narration?.playbackPosition, "Playback position missing")
            try check(abs(savedPosition - resumeAt) < 0.2, "Native playback seek and stop persist the audio position")
            narrator.togglePlayback(item: narratedArticle, store: store)
            try check(abs(narrator.position - savedPosition) < 0.2, "Playback resumes from the database even with a stale library-item snapshot")
            narrator.stopPlayback()
            let articleAudioHash = try hash(articleAudio)
            narrator.generate(item: narratedArticle, store: store)
            try check(narrator.isBusy, "A replacement narration starts as a separate job")
            narrator.cancel(); try await wait(narrator, seconds: 30)
            try check(narrator.phase == "Cancelled" && (try store.item(id: article.id)?.narration?.id) == articleRecord.id
                && (try hash(articleAudio)) == articleAudioHash, "Cancelling a replacement preserves the previous committed MP3")

            let fixtureHash = try hash(fixture)
            let importer = ArticleImporter()
            let preparedPDF = try await importer.preparePDF(fileURL: fixture)
            defer { preparedPDF.cleanup() }
            let pdfItem = ReaderItem(title: "Reader narrated PDF fixture", kind: .pdf, contentPath: preparedPDF.contentPath, text: preparedPDF.text)
            try store.addItem(pdfItem, from: preparedPDF.directory); try model.refresh()
            let managedPDF = try store.contentURL(for: pdfItem)
            narrator.generate(item: pdfItem, store: store)
            try check(narrator.isBusy, "Native controller launches the managed PDF narration path")
            model.select(article.id); model.performNarrationAction()
            try check(narrator.isPlaying && narrator.isGenerating(pdfItem.id), "A saved narration can play while another document generates in the background")
            model.performNarrationAction(); narrator.stopPlayback()
            try await wait(narrator)
            let narratedPDF = try required(try store.item(id: pdfItem.id), "Narrated PDF missing")
            let pdfRecord = try required(narratedPDF.narration, narrator.error ?? "PDF narration produced no committed result")
            let pdfAudio = try required(try store.narrationAudioURL(for: narratedPDF), "PDF MP3 missing")
            let pdfDirectory = pdfAudio.deletingLastPathComponent()
            let pageTokens = ["persimmon-1", "persimmon-2", "persimmon-3"]
            let extractedPDFText = try String(contentsOf: pdfDirectory.appendingPathComponent("extracted.txt"), encoding: .utf8)
            let spokenPDFText = try String(contentsOf: pdfDirectory.appendingPathComponent("script.txt"), encoding: .utf8)
            try check(pageTokens.allSatisfy { extractedPDFText.contains($0) },
                      "Layout-aware PDF extraction includes text from all normal and rotated pages")
            try check(pageTokens.allSatisfy { spokenPDFText.contains($0) },
                      "Prepared PDF narration retains every page's unique body passage")
            let pdfDecoded = try AVAudioPlayer(contentsOf: pdfAudio)
            try check(pdfDecoded.duration > 2 && pdfDecoded.prepareToPlay(), "AVAudioPlayer decodes actual PDF narration audio")
            let pdfMetadata = try dictionary(pdfDirectory.appendingPathComponent("metadata.json"))
            try check(pdfMetadata["sourcePDFSHA256"] as? String == fixtureHash,
                      "PDF narration records the managed source identity in its provenance")
            try check(try hash(managedPDF) == fixtureHash && hash(fixture) == fixtureHash,
                      "Layout-aware text cleanup and speech generation leave both PDF originals intact")
            let pdfAudioHash = try hash(pdfAudio)

            // Simulate an unavailable managed source in this disposable library;
            // restore it before export. The independent source fixture is untouched.
            let heldPDF = root.appendingPathComponent("Work/Preserved-fixture.pdf")
            try fm.moveItem(at: managedPDF, to: heldPDF)
            var sourceHeld = true
            defer { if sourceHeld { try? fm.moveItem(at: heldPDF, to: managedPDF) } }
            narrator.generate(item: narratedPDF, store: store)
            try await wait(narrator)
            try check(narrator.error != nil && narrator.phase == "Narration failed", "A missing source causes a clear native pipeline failure")
            try check((try store.item(id: pdfItem.id)?.narration?.id) == pdfRecord.id && (try hash(pdfAudio)) == pdfAudioHash,
                      "A failed replacement preserves the previous PDF MP3 and record")
            try check(narrator.jobDirectory.map { fm.fileExists(atPath: $0.path) } == true,
                      "Failed narration keeps its staged job available for recovery")
            try fm.moveItem(at: heldPDF, to: managedPDF); sourceHeld = false
            narrator.stopPlayback(); store.close()

            let reopened = try LibraryStore(root: root)
            defer { reopened.close() }
            let reopenedArticle = try required(try reopened.item(id: article.id), "Article missing after reopen")
            let reopenedPDF = try required(try reopened.item(id: pdfItem.id), "PDF missing after reopen")
            try check(reopenedArticle.narration?.id == articleRecord.id && reopenedPDF.narration?.id == pdfRecord.id,
                      "Both generated narration records persist after database close/reopen")
            try check(abs((reopenedArticle.narration?.playbackPosition ?? -1) - savedPosition) < 0.2,
                      "Audio playback progress survives library reopen")
            let offlineDefaultsName = "Reader.OfflinePlaybackVerification.\(UUID().uuidString)"
            let offlineDefaults = UserDefaults(suiteName: offlineDefaultsName)!
            defer { offlineDefaults.removePersistentDomain(forName: offlineDefaultsName) }
            offlineDefaults.set(root.appendingPathComponent("Models-not-installed").path, forKey: "narrationModels")
            let coldPlayer = NarrationController(defaults: offlineDefaults, usesOpenAI: false)
            coldPlayer.togglePlayback(item: reopenedArticle, store: reopened)
            try check(!coldPlayer.isReady && coldPlayer.isPlaying && coldPlayer.duration > 2 && !coldPlayer.isBusy && coldPlayer.jobDirectory == nil,
                      "A fresh controller plays saved audio after library reopen with generation models unavailable")
            coldPlayer.seek(savedPosition); coldPlayer.stopPlayback()
            let snapshot = root.deletingLastPathComponent().appendingPathComponent("ReaderNarrationSnapshot-\(UUID().uuidString)")
            let restoredRoot = root.deletingLastPathComponent().appendingPathComponent("ReaderNarrationRestore-\(UUID().uuidString)")
            try reopened.exportLibrary(to: snapshot); try LibraryStore.restore(from: snapshot, to: restoredRoot)
            let restored = try LibraryStore(root: restoredRoot)
            defer { restored.close() }
            try restored.validateContent()
            let restoredArticle = try required(try restored.item(id: article.id), "Restored article missing")
            let restoredPDF = try required(try restored.item(id: pdfItem.id), "Restored PDF missing")
            let restoredArticleAudio = try required(try restored.narrationAudioURL(for: restoredArticle), "Restored article MP3 missing")
            let restoredPDFAudio = try required(try restored.narrationAudioURL(for: restoredPDF), "Restored PDF MP3 missing")
            try check(try hash(restoredArticleAudio) == articleAudioHash && hash(restoredPDFAudio) == pdfAudioHash,
                      "Complete export and separate restore preserve both generated MP3s byte for byte")
            try check(fm.fileExists(atPath: restoredArticleAudio.deletingLastPathComponent().appendingPathComponent("plan.json").path)
                && fm.fileExists(atPath: restoredPDFAudio.deletingLastPathComponent().appendingPathComponent("metadata.json").path),
                      "Restore retains cleanup plans and narration provenance alongside audio")
            try check(!fm.fileExists(atPath: root.appendingPathComponent("Models").path),
                      "Regenerable model weights remain separate from durable reading content")
            print("NARRATION VERIFICATION PASSED: \(count) checks. Temporary library: \(root.path)")
            fflush(stdout); return true
        } catch {
            print("NARRATION VERIFICATION FAILED: \(error.localizedDescription)")
            print("Temporary library, if created: \(root.path)")
            fflush(stdout); return false
        }
    }
}
