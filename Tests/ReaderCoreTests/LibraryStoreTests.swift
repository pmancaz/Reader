import Foundation
import CSQLite
@testable import ReaderCore

final class LibraryStoreTests {
    var scratch: URL!
    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Reader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: scratch) }
    func makeStage(name: String = "original.pdf", data: Data = Data("%PDF fixture original".utf8)) throws -> URL {
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try data.write(to: url.appendingPathComponent(name))
        return url
    }
    func makeStore() throws -> LibraryStore { try LibraryStore(root: scratch.appendingPathComponent("Library"), createIfMissing: true) }

    func testLibraryContentAndAnnotationsSurviveReopenAndSearch() throws {
        var store: LibraryStore? = try makeStore()
        let root = store!.root
        let stage = try makeStage()
        var item = LibraryItem(title: "A careful reader", kind: .pdf, author: "Pat", originalURL: "https://example.org/article?utm_source=test", contentPath: "original.pdf", text: "A text layer for offline searching", tags: ["Research"])
        try store!.addItem(item, from: stage)
        let original = try Data(contentsOf: store!.contentURL(for: item))
        var note = ReaderAnnotation(itemID: item.id, quote: "selected phrase", note: "A quiet observation", pdfRects: [.init(pageIndex: 2, x: 25, y: 43, width: 100, height: 12)])
        try store!.saveAnnotation(note)
        note.note += " and revision"
        try store!.saveAnnotation(note)
        item.title = "Edited title"; item.isFavorite = true; item.isArchived = true
        item.trashedAt = Date(); item.tags = ["Research", "Music"]
        try store!.updateItem(item)
        let progress = ReadingProgress(fraction: 0.42, pageIndex: 2, zoom: 1.7, pageRotation: 90, pdfX: 5, pdfY: 200)
        try store!.saveProgress(itemID: item.id, progress: progress)
        try expectEqual(try store!.search("quiet revision").map(\.id), [item.id])
        try expectEqual(try store!.search("offline Music").map(\.id), [item.id])
        try expectNotNil(try store!.duplicate(forURL: URL(string: "https://EXAMPLE.org/article?utm_campaign=x#top")!))
        store!.close(); store = nil
        let reopened = try LibraryStore(root: root)
        let saved = try requireValue(reopened.item(id: item.id))
        try expectEqual(saved.progress, progress); try expectEqual(saved.status, .reading)
        try expectEqual(saved.tags, ["Research", "Music"]); try expectNotNil(saved.trashedAt)
        try expectTrue(saved.isArchived); try expectTrue(saved.isFavorite)
        try expectEqual(try reopened.annotations(itemID: item.id), [note])
        let localPDFNotes = root.appendingPathComponent("Exports/PDF-notes.md")
        try reopened.exportMarkdown(to: localPDFNotes)
        try expectTrue(try String(contentsOf: localPDFNotes, encoding: .utf8).contains("- Local file: Items/\(item.id)/original.pdf"))
        try expectEqual(try Data(contentsOf: reopened.contentURL(for: saved)), original)
        try expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library.sqlite-wal").path))
        var restored = saved; restored.trashedAt = nil; restored.isArchived = false
        try reopened.updateItem(restored)
        try expectNil(try reopened.item(id: item.id)?.trashedAt)
        reopened.close()
    }

    func testCompleteBackupRestoreAndMarkdownExport() throws {
        let store = try makeStore()
        let stage = try makeStage(name: "article.html", data: Data("<article><h1>Offline heading</h1><img src='image.png'></article>".utf8))
        try Data([1,2,3,4]).write(to: stage.appendingPathComponent("image.png"))
        let item = LibraryItem(title: "Article", kind: .article, originalURL: "https://example.org/story", contentPath: "article.html", text: "Offline heading")
        try store.addItem(item, from: stage)
        let annotation = ReaderAnnotation(itemID: item.id, quote: "Offline heading", note: "My durable writing", articleAnchor: .init(exact: "Offline heading", prefix: "Before", suffix: "after", start: 2, end: 17))
        try store.saveAnnotation(annotation)
        let snapshot = try store.backup()
        try LibraryStore.verifySnapshot(snapshot)
        try expectThrows(try LibraryStore(root: snapshot, createIfMissing: true)) { error in
            try expectTrue(error.localizedDescription.contains("Restore Backup"))
        }
        try LibraryStore.verifySnapshot(snapshot) // Rejected opens must leave the snapshot unchanged.
        try expectFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent(".reader.lock").path))
        try expectFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("Backups").path))
        let destination = scratch.appendingPathComponent("Restored")
        try LibraryStore.restore(from: snapshot, to: destination)
        let restored = try LibraryStore(root: destination)
        let restoredItem = try requireValue(restored.item(id: item.id))
        try expectEqual(restoredItem, item)
        try expectEqual(try restored.annotations(itemID: item.id), [annotation])
        try expectEqual(try Data(contentsOf: restored.contentURL(for: item)), Data(contentsOf: stage.appendingPathComponent("article.html")))
        try expectEqual(try Data(contentsOf: restored.contentURL(for: item).deletingLastPathComponent().appendingPathComponent("image.png")), Data([1,2,3,4]))
        let markdown = store.root.appendingPathComponent("Exports/Notes.md")
        try restored.exportMarkdown(to: markdown)
        let text = try String(contentsOf: markdown, encoding: .utf8)
        try expectTrue(text.contains("My durable writing")); try expectTrue(text.contains("https://example.org/story")); try expectTrue(text.contains("> Offline heading"))
        try expectThrows(try LibraryStore.restore(from: snapshot, to: destination))
        restored.close(); store.close()
    }

    func testRestoreRejectsCorruptionWithoutCreatingDestination() throws {
        let store = try makeStore()
        let item = LibraryItem(title: "PDF", kind: .pdf, contentPath: "original.pdf")
        try store.addItem(item, from: makeStage())
        let backup = try store.backup()
        let backupContent = backup.appendingPathComponent("Items").appendingPathComponent(item.id).appendingPathComponent(item.contentPath)
        try Data("corrupt".utf8).write(to: backupContent)
        let destination = scratch.appendingPathComponent("No restore")
        try expectThrows(try LibraryStore.restore(from: backup, to: destination))
        try expectFalse(FileManager.default.fileExists(atPath: destination.path))
        try expectEqual(try Data(contentsOf: store.contentURL(for: item)), Data("%PDF fixture original".utf8))
        store.close()
    }

    func testSingleWriterMissingLibraryAndClosedStore() throws {
        let store = try makeStore()
        let ignore = store.root.appendingPathComponent(".gitignore")
        try expectEqual(try String(contentsOf: ignore, encoding: .utf8), "*\n!.gitignore\n")
        try expectThrows(try LibraryStore(root: store.root)) { error in
            guard case LibraryError.busy = error else { return try recordFailure("Expected local writer lock, got \(error)") }
        }
        store.close()
        try expectThrows(try store.items())
        let reopened = try LibraryStore(root: store.root)
        reopened.close()
        let marker = store.root.appendingPathComponent("Library.json")
        let markerData = try Data(contentsOf: marker)
        let originalDatabase = try Data(contentsOf: store.databaseURL)
        try FileManager.default.removeItem(at: marker)
        try expectThrows(try LibraryStore(root: store.root, createIfMissing: true))
        try expectFalse(FileManager.default.fileExists(atPath: marker.path))
        try expectEqual(try Data(contentsOf: store.databaseURL), originalDatabase)
        for invalidMarker in ["not JSON", "{\"format\":\"Another application\",\"version\":1}", "{\"format\":\"Reader Library\",\"version\":2}"] {
            try Data(invalidMarker.utf8).write(to: marker)
            try expectThrows(try LibraryStore(root: store.root))
            try expectEqual(try Data(contentsOf: marker), Data(invalidMarker.utf8))
            try expectEqual(try Data(contentsOf: store.databaseURL), originalDatabase)
        }
        try markerData.write(to: marker)
        let customizedIgnore = "*\n!.gitignore\n# User instruction preserved\n"
        try Data(customizedIgnore.utf8).write(to: ignore)
        let verified = try LibraryStore(root: store.root)
        try expectEqual(try String(contentsOf: ignore, encoding: .utf8), customizedIgnore)
        verified.close()
        let missing = scratch.appendingPathComponent("Missing")
        try expectThrows(try LibraryStore(root: missing))
        try expectFalse(FileManager.default.fileExists(atPath: missing.path))
        let incomplete = scratch.appendingPathComponent("Incomplete")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: false)
        try markerData.write(to: incomplete.appendingPathComponent("Library.json"))
        try expectThrows(try LibraryStore(root: incomplete, createIfMissing: true)) { error in
            try expectTrue(error.localizedDescription.contains("incomplete"))
        }
        try expectFalse(FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("Library.sqlite").path))
        let nonempty = try makeStage()
        try expectThrows(try LibraryStore(root: nonempty, createIfMissing: true))
    }

    func testUnsafeImportsAndReplacementAreRejected() throws {
        let store = try makeStore()
        let stage = try makeStage()
        let bad = LibraryItem(id: "../escape", title: "Unsafe", kind: .pdf, contentPath: "original.pdf")
        try expectThrows(try store.addItem(bad, from: stage))
        let badPath = LibraryItem(title: "Unsafe path", kind: .pdf, contentPath: "../original.pdf")
        try expectThrows(try store.addItem(badPath, from: stage))
        let linked = try makeStage()
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("outside"), withDestinationURL: scratch)
        let item = LibraryItem(title: "Valid", kind: .pdf, contentPath: "original.pdf")
        try expectThrows(try store.addItem(item, from: linked))
        try store.addItem(item, from: stage)
        try expectThrows(try store.addItem(item, from: stage))
        var changed = item; changed.contentPath = "replacement.pdf"
        try expectThrows(try store.updateItem(changed))
        try expectEqual(try store.items().count, 1)
        store.close()
    }

    func testAnnotationCannotMoveBetweenDocuments() throws {
        let store = try makeStore()
        let a = LibraryItem(title: "A", kind: .pdf, contentPath: "original.pdf")
        let b = LibraryItem(title: "B", kind: .pdf, contentPath: "original.pdf")
        try store.addItem(a, from: makeStage()); try store.addItem(b, from: makeStage())
        var note = ReaderAnnotation(itemID: a.id, note: "A")
        try store.saveAnnotation(note)
        note.itemID = b.id
        try expectThrows(try store.saveAnnotation(note))
        try expectEqual(try store.annotations(itemID: a.id).count, 1)
        try expectEqual(try store.annotations(itemID: b.id).count, 0)
        try store.deleteAnnotation(id: note.id)
        try expectEqual(try store.annotations(itemID: a.id).count, 0)
        store.close()
    }

    func testNarrationPersistenceVersionsAndRestore() throws {
        let store = try makeStore()
        let item = LibraryItem(title: "Narration source", kind: .article, contentPath: "article.html", text: "Text for local narration")
        try store.addItem(item, from: makeStage(name: "article.html", data: Data("<article>Text for local narration</article>".utf8)))
        // An item payload from before the narration feature remains readable without migration.
        var oldPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        oldPayload.removeValue(forKey: "narration")
        let oldItem = try JSONDecoder().decode(LibraryItem.self, from: JSONSerialization.data(withJSONObject: oldPayload))
        try expectNil(oldItem.narration)
        let firstJob = try makeStage(name: "audio.mp3", data: Data("ID3-first-completed-audio".utf8))
        try Data("Cleaned first script".utf8).write(to: firstJob.appendingPathComponent("script.txt"))
        let first = try store.saveNarration(itemID: item.id, from: firstJob, voice: "af_heart", speed: 1, duration: 80)
        var current = try requireValue(store.item(id: item.id))
        let firstAudioURL = try requireValue(store.narrationAudioURL(for: current))
        try expectEqual(try Data(contentsOf: firstAudioURL), Data("ID3-first-completed-audio".utf8))
        try expectEqual(first.playbackPosition, 0)
        var oldRecordPayload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        oldRecordPayload.removeValue(forKey: "playbackPosition")
        let defaultPosition = try JSONDecoder().decode(NarrationRecord.self, from: JSONSerialization.data(withJSONObject: oldRecordPayload))
        try expectEqual(defaultPosition.playbackPosition, 0)
        let secondJob = try makeStage(name: "audio.mp3", data: Data("ID3-second-completed-audio".utf8))
        try Data("Cleaned second script".utf8).write(to: secondJob.appendingPathComponent("script.txt"))
        let provenance: [String: String] = ["extracted.txt": "Original extracted article", "plan.json": "{\"reversibleCleanup\":true}",
                                            "metadata.json": "{\"sourceHash\":\"fixture-hash\"}", "request.json": "{\"voice\":\"bf_emma\"}",
                                            "result.json": "{\"success\":true}", "input.txt": "Original worker input"]
        for (name, text) in provenance { try Data(text.utf8).write(to: secondJob.appendingPathComponent(name)) }
        try Data("disposable intermediate".utf8).write(to: secondJob.appendingPathComponent("intermediate.wav"))
        try FileManager.default.createDirectory(at: secondJob.appendingPathComponent("chunks"), withIntermediateDirectories: false)
        try Data("chunk".utf8).write(to: secondJob.appendingPathComponent("chunks/0.wav"))
        let second = try store.saveNarration(itemID: item.id, from: secondJob, voice: "bf_emma", speed: 0.9, duration: 100)
        try expectFalse(first.id == second.id)
        try expectEqual(try Data(contentsOf: firstAudioURL), Data("ID3-first-completed-audio".utf8))
        // A stale title editor must not discard a newly completed background narration.
        var stale = item; stale.title = "Edited while generating"
        try store.updateItem(stale)
        try store.saveNarrationPosition(itemID: item.id, seconds: 37.25)
        current = try requireValue(store.item(id: item.id))
        try expectEqual(current.narration?.id, second.id)
        try expectEqual(current.title, "Edited while generating")
        try expectEqual(current.narration?.playbackPosition, 37.25)
        let incomplete = try makeStage(name: "audio.mp3", data: Data())
        try expectThrows(try store.saveNarration(itemID: item.id, from: incomplete, voice: "af_heart", speed: 1))
        try expectEqual(try store.item(id: item.id)?.narration?.id, second.id)
        try expectThrows(try store.saveNarrationPosition(itemID: item.id, seconds: -.infinity))
        try expectThrows(try store.narrationContentURL(for: current, relativePath: "../outside.mp3"))
        try expectThrows(try store.narrationContentURL(for: current, relativePath: "/outside.mp3"))
        try store.saveAnnotation(.init(itemID: item.id, note: "My note remains beside generated audio"))
        let exportedNotes = store.root.appendingPathComponent("Exports/Narration-notes.md")
        try store.exportMarkdown(to: exportedNotes)
        try expectTrue(try String(contentsOf: exportedNotes, encoding: .utf8).contains(second.relativeScriptPath))
        let exported = scratch.appendingPathComponent("Narration snapshot")
        try store.exportLibrary(to: exported)
        store.close()
        let reopened = try LibraryStore(root: store.root)
        try expectEqual(try reopened.item(id: item.id)?.narration?.playbackPosition, 37.25)
        reopened.close()
        let restoredURL = scratch.appendingPathComponent("Narration restored")
        try LibraryStore.restore(from: exported, to: restoredURL)
        let restored = try LibraryStore(root: restoredURL)
        try restored.validateContent()
        let restoredItem = try requireValue(restored.item(id: item.id))
        let restoredAudio = try requireValue(restored.narrationAudioURL(for: restoredItem))
        let restoredScript = try requireValue(restored.narrationScriptURL(for: restoredItem))
        try expectEqual(try Data(contentsOf: restoredAudio), Data("ID3-second-completed-audio".utf8))
        try expectEqual(try String(contentsOf: restoredScript, encoding: .utf8), "Cleaned second script")
        try expectEqual(restoredItem.narration?.playbackPosition, 37.25)
        for (name, text) in provenance {
            let file = restoredAudio.deletingLastPathComponent().appendingPathComponent(name)
            try expectEqual(try String(contentsOf: file, encoding: .utf8), text)
        }
        try expectFalse(FileManager.default.fileExists(atPath: restoredAudio.deletingLastPathComponent().appendingPathComponent("intermediate.wav").path))
        try expectFalse(FileManager.default.fileExists(atPath: restoredAudio.deletingLastPathComponent().appendingPathComponent("chunks").path))
        let restoredOlderAudio = try restored.narrationContentURL(for: restoredItem, relativePath: first.relativeAudioPath)
        try expectEqual(try Data(contentsOf: restoredOlderAudio), Data("ID3-first-completed-audio".utf8))
        try FileManager.default.removeItem(at: restoredScript)
        try expectThrows(try restored.validateContent())
        restored.close()
    }

    func testBeforeMigrationBackupAndDropboxConflictProtection() throws {
        let root = scratch.appendingPathComponent("Legacy")
        let initial = try LibraryStore(root: root, createIfMissing: true)
        initial.close()
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(root.appendingPathComponent("Library.sqlite").path, &db), SQLITE_OK)
        try expectEqual(sqlite3_exec(db, "CREATE TABLE prior_state(note TEXT); INSERT INTO prior_state VALUES('preserve me'); PRAGMA user_version=0", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try LibraryStore(root: root)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Backups").path)
        try expectTrue(backups.contains { $0.hasPrefix("Before-migration") })
        store.close()
        try Data("conflict".utf8).write(to: root.appendingPathComponent("Library (Mac conflicted copy 2026).sqlite"))
        try expectThrows(try LibraryStore(root: root))
        try expectEqual(try Data(contentsOf: root.appendingPathComponent("Library (Mac conflicted copy 2026).sqlite")), Data("conflict".utf8))
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func expectEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) throws {
    let left = try lhs(), right = try rhs()
    guard left == right else { throw CheckFailure(description: "\(file):\(line): Expected \(right), received \(left)") }
}
private func expectTrue(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try expression() else { throw CheckFailure(description: "\(file):\(line): Expected true") }
}
private func expectFalse(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try !expression() else { throw CheckFailure(description: "\(file):\(line): Expected false") }
}
private func expectNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try expression() == nil else { throw CheckFailure(description: "\(file):\(line): Expected nil") }
}
private func expectNotNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try expression() != nil else { throw CheckFailure(description: "\(file):\(line): Expected a value") }
}
private func expectThrows<T>(_ operation: @autoclosure () throws -> T, _ onError: ((Error) throws -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
    do { _ = try operation() } catch { try onError?(error); return }
    throw CheckFailure(description: "\(file):\(line): Expected operation to throw")
}
private func requireValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "\(file):\(line): Required value is missing") }
    return value
}
private func recordFailure(_ message: String) throws { throw CheckFailure(description: message) }
