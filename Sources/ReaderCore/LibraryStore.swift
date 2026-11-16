import Foundation
import CSQLite
import Darwin
import CryptoKit

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One local writer. All public operations serialize through a recursive lock.
/// Dropbox must never be used as concurrent database replication.
public final class LibraryStore: @unchecked Sendable {
    /// Keep the default library beside this source checkout, including on another Mac.
    /// Existing installations continue to use their saved, explicitly selected path.
    public static let defaultRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ReaderData", isDirectory: true)
    public let root: URL
    public private(set) var lastBackupError: String?
    private var db: OpaquePointer?
    private var lockFD: Int32 = -1
    private let mutex = NSRecursiveLock()
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastBackupAt: Date?
    private var closed = false
    private var dirtySinceBackup = false
    public var databaseURL: URL { root.appendingPathComponent("Library.sqlite") }

    public init(root: URL = LibraryStore.defaultRoot, createIfMissing: Bool = false) throws {
        self.root = root.standardizedFileURL
        encoder.outputFormatting = [.sortedKeys]
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: self.root.path, isDirectory: &isDirectory)
        guard (exists && isDirectory.boolValue) || createIfMissing else { throw LibraryError.missing(self.root.path) }
        if !exists { try fm.createDirectory(at: self.root, withIntermediateDirectories: true) }
        guard !fm.fileExists(atPath: self.root.appendingPathComponent("Snapshot.json").path) else {
            throw LibraryError.invalid("This folder is a backup snapshot. Use Restore Backup to restore it into a new folder before opening it. The original backup has been preserved.")
        }
        guard fm.isReadableFile(atPath: self.root.path), fm.isWritableFile(atPath: self.root.path) else { throw LibraryError.missing(self.root.path) }
        let dbExists = fm.fileExists(atPath: databaseURL.path)
        if !dbExists && !createIfMissing { throw LibraryError.invalid("No Library.sqlite was found in the selected folder. If this is an incomplete library, preserve the folder and restore a verified backup into a new location.") }
        let markerURL = self.root.appendingPathComponent("Library.json")
        if dbExists {
            guard fm.fileExists(atPath: markerURL.path) else {
                throw LibraryError.invalid("Library.json is missing beside the existing database. This may be an incomplete or partially recovered library. Reader has preserved the database; restore a verified backup into a new folder or locate the complete library.")
            }
            let marker: LibraryMarker
            do { marker = try decoder.decode(LibraryMarker.self, from: Data(contentsOf: markerURL)) }
            catch { throw LibraryError.invalid("Library.json cannot be read or is invalid. Reader has preserved the database. Locate the complete library or restore a verified backup into a new folder.") }
            guard marker.format == "Reader Library", marker.version == 1 else {
                throw LibraryError.invalid("Library.json does not identify a supported Reader Library. Reader has preserved the database; choose the correct library or restore a verified backup into a new folder.")
            }
        }
        if !dbExists {
            guard !fm.fileExists(atPath: markerURL.path) else {
                throw LibraryError.invalid("Library.json exists but Library.sqlite is missing. This library is incomplete and has been preserved. Locate the complete library or restore a verified backup into a new folder.")
            }
            let unknown = try fm.contentsOfDirectory(atPath: self.root.path).filter { ![".DS_Store", ".reader.lock"].contains($0) }
            guard unknown.isEmpty else { throw LibraryError.invalid("The folder is not empty and does not contain a Reader library. Choose an empty folder to create a new library.") }
        }
        lockFD = Darwin.open(self.root.appendingPathComponent(".reader.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw LibraryError.io("Cannot lock the library folder. Check its permissions.") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lockFD); lockFD = -1; throw LibraryError.busy }
        do {
            let conflicts = try fm.contentsOfDirectory(atPath: self.root.path).filter { $0.localizedCaseInsensitiveContains("conflicted copy") && $0.localizedCaseInsensitiveContains("sqlite") }
            guard conflicts.isEmpty else { throw LibraryError.invalid("Dropbox database conflict copies were found: \(conflicts.joined(separator: ", ")). Preserve both copies and choose the library to recover; Reader will not overwrite either.") }
            guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw databaseError() }
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            let version = try scalarInt("PRAGMA user_version")
            guard version <= 1 else { throw LibraryError.invalid("This library was created by a newer Reader. Update Reader before opening it.") }
            if version < 1 {
                if dbExists { _ = try createSnapshot(prefix: "Before-migration") }
                try transaction {
                    try execute("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, canonical_url TEXT, added REAL NOT NULL)")
                    try execute("CREATE INDEX IF NOT EXISTS items_url ON items(canonical_url)")
                    try execute("CREATE TABLE IF NOT EXISTS annotations (id TEXT PRIMARY KEY NOT NULL, item_id TEXT NOT NULL REFERENCES items(id), payload BLOB NOT NULL)")
                    try execute("CREATE INDEX IF NOT EXISTS annotations_item ON annotations(item_id)")
                    try execute("PRAGMA user_version=1")
                }
            }
            try validateDatabase()
            for name in ["Items", "Backups", "Exports"] { try fm.createDirectory(at: self.root.appendingPathComponent(name), withIntermediateDirectories: true) }
            let marker = markerURL
            if !dbExists {
                let data = try JSONSerialization.data(withJSONObject: ["format": "Reader Library", "version": 1, "id": UUID().uuidString], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: marker, options: .atomic)
            }
            let ignoreURL = self.root.appendingPathComponent(".gitignore")
            if !fm.fileExists(atPath: ignoreURL.path) {
                try Data("*\n!.gitignore\n".utf8).write(to: ignoreURL, options: .withoutOverwriting)
            }
            let backups = (try? fm.contentsOfDirectory(at: self.root.appendingPathComponent("Backups"), includingPropertiesForKeys: [.creationDateKey])) ?? []
            lastBackupAt = backups.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.max()
            if dbExists { automaticBackupIfNeeded() }
        } catch {
            if let db { sqlite3_close_v2(db); self.db = nil }
            flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1
            throw error
        }
    }

    deinit { close() }
    public func close() {
        mutex.lock(); defer { mutex.unlock() }
        guard !closed else { return }
        if dirtySinceBackup && db != nil {
            do { _ = try backup() } catch { lastBackupError = error.localizedDescription }
        }
        closed = true
        if let db { sqlite3_close_v2(db); self.db = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }

    public func items() throws -> [LibraryItem] {
        mutex.lock(); defer { mutex.unlock() }
        return try query("SELECT payload FROM items ORDER BY added DESC").map { try decoder.decode(LibraryItem.self, from: $0) }
    }
    public func item(id: String) throws -> LibraryItem? {
        mutex.lock(); defer { mutex.unlock() }
        return try query("SELECT payload FROM items WHERE id=?", strings: [id]).first.map { try decoder.decode(LibraryItem.self, from: $0) }
    }
    public func duplicate(forURL url: URL) throws -> LibraryItem? {
        mutex.lock(); defer { mutex.unlock() }
        return try query("SELECT payload FROM items WHERE canonical_url=? ORDER BY added LIMIT 1", strings: [Self.canonicalURL(url)]).first.map { try decoder.decode(LibraryItem.self, from: $0) }
    }
    public static func canonicalURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        parts.fragment = nil; parts.host = parts.host?.lowercased(); parts.scheme = parts.scheme?.lowercased()
        if parts.path == "/" { parts.path = "" }
        let ignored = Set(["fbclid", "gclid", "mc_cid", "mc_eid", "ref_src"])
        parts.queryItems = parts.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !ignored.contains($0.name.lowercased()) }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.string ?? url.absoluteString
    }

    public func addItem(_ item: LibraryItem, from directory: URL) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validate(item)
        guard try self.item(id: item.id) == nil else { throw LibraryError.invalid("An item with this identifier already exists.") }
        let source = directory.standardizedFileURL
        try Self.validateTree(source)
        let sourceFile = source.appendingPathComponent(item.contentPath).standardizedFileURL
        guard sourceFile.path.hasPrefix(source.path + "/"),
              try sourceFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryError.invalid("The imported reading file is missing or is not a regular file.") }
        let destination = root.appendingPathComponent("Items", isDirectory: true).appendingPathComponent(item.id, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.invalid("An import folder already exists with this identifier. It was preserved for recovery.") }
        try fm.copyItem(at: source, to: destination)
        do { try transaction { try writeItem(item, insert: true) } }
        catch { try? fm.removeItem(at: destination); throw error }
        dirtySinceBackup = true
        automaticBackupIfNeeded()
    }
    public func updateItem(_ item: LibraryItem) throws {
        mutex.lock(); defer { mutex.unlock() }
        try validate(item)
        guard let previous = try self.item(id: item.id) else { throw LibraryError.invalid("This item no longer exists.") }
        guard previous.contentPath == item.contentPath, previous.kind == item.kind else { throw LibraryError.invalid("Imported content cannot be replaced through metadata editing.") }
        // Narration changes use dedicated atomic methods. Preserve the latest record when
        // an editor submits metadata captured before a background generation completed.
        var updated = item
        updated.narration = previous.narration
        try transaction { try writeItem(updated, insert: false) }
        dirtySinceBackup = true
        automaticBackupIfNeeded()
    }
    public func saveProgress(itemID: String, progress: ReadingProgress) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard var item = try item(id: itemID) else { throw LibraryError.invalid("The reading item no longer exists.") }
        item.progress = progress
        if item.status == .unread && progress.fraction > 0.001 { item.status = .reading }
        try updateItem(item)
    }
    public func contentURL(for item: LibraryItem) throws -> URL {
        try validate(item)
        let directory = root.appendingPathComponent("Items").appendingPathComponent(item.id)
        let result = directory.appendingPathComponent(item.contentPath).standardizedFileURL
        guard result.resolvingSymlinksInPath().path.hasPrefix(directory.standardizedFileURL.path + "/") else { throw LibraryError.invalid("The reading file resolves outside its item folder.") }
        return result
    }
    /// Commits only completed narration jobs. Original documents and all earlier audio
    /// versions remain intact; an interrupted generation never replaces the latest record.
    @discardableResult public func saveNarration(itemID: String, from stagedDir: URL, voice: String,
                                                speed: Double, duration: Double? = nil) throws -> NarrationRecord {
        mutex.lock(); defer { mutex.unlock() }
        guard var current = try item(id: itemID) else { throw LibraryError.invalid("The narration's reading item no longer exists.") }
        try validate(current)
        guard !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, speed.isFinite, speed > 0,
              duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw LibraryError.invalid("The narration voice, speed or duration is invalid.") }
        let source = stagedDir.standardizedFileURL
        try Self.validateTree(source)
        for name in ["audio.mp3", "script.txt"] {
            let file = source.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw LibraryError.invalid("The narration job is incomplete: \(name) is missing or empty. Existing audio has been preserved.") }
        }
        guard !(try String(contentsOf: source.appendingPathComponent("script.txt"), encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryError.invalid("The narration script is empty. Existing audio has been preserved.")
        }
        let id = UUID().uuidString
        let relativeDirectory = "Narrations/\(id)"
        let directory = try narrationContentURL(for: current, relativePath: relativeDirectory)
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: directory.path) else { throw LibraryError.invalid("The narration destination already exists. Existing audio has been preserved.") }
        let staging = parent.appendingPathComponent(".staging-\(id)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var moved = false
        do {
            let retainedFiles = ["audio.mp3", "script.txt", "extracted.txt", "plan.json", "metadata.json", "request.json", "result.json", "input.txt"]
            for name in retainedFiles {
                let file = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: file.path) else { continue }
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw LibraryError.invalid("The narration provenance file \(name) is not a regular file.")
                }
                try fm.copyItem(at: file, to: staging.appendingPathComponent(name))
            }
            try fm.moveItem(at: staging, to: directory)
            moved = true
            let record = NarrationRecord(id: id, relativeAudioPath: "\(relativeDirectory)/audio.mp3",
                                         relativeScriptPath: "\(relativeDirectory)/script.txt", voice: voice, speed: speed, duration: duration)
            current.narration = record
            try transaction { try writeItem(current, insert: false) }
            dirtySinceBackup = true
            automaticBackupIfNeeded()
            return record
        } catch {
            // Both paths belong solely to this new UUID; older versions are never removed.
            try? fm.removeItem(at: moved ? directory : staging)
            throw error
        }
    }
    public func saveNarrationPosition(itemID: String, seconds: Double) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard seconds.isFinite, seconds >= 0 else { throw LibraryError.invalid("The audio playback position is invalid.") }
        guard var current = try item(id: itemID), var record = current.narration else { throw LibraryError.invalid("This item has no completed narration.") }
        record.playbackPosition = min(seconds, record.duration ?? seconds)
        current.narration = record
        try validate(current)
        try transaction { try writeItem(current, insert: false) }
        dirtySinceBackup = true
        automaticBackupIfNeeded()
    }
    public func narrationAudioURL(for item: LibraryItem) throws -> URL? {
        guard let record = item.narration else { return nil }
        return try narrationContentURL(for: item, relativePath: record.relativeAudioPath)
    }
    public func narrationScriptURL(for item: LibraryItem) throws -> URL? {
        guard let record = item.narration else { return nil }
        return try narrationContentURL(for: item, relativePath: record.relativeScriptPath)
    }
    public func narrationContentURL(for item: LibraryItem, relativePath: String) throws -> URL {
        try validate(item)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw LibraryError.invalid("Unsafe narration content path.") }
        let directory = root.appendingPathComponent("Items").appendingPathComponent(item.id).standardizedFileURL
        let result = directory.appendingPathComponent(relativePath).standardizedFileURL
        guard result.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(directory.path + "/") else {
            throw LibraryError.invalid("The narration file resolves outside its item folder.")
        }
        return result
    }
    public func annotations(itemID: String) throws -> [ReaderAnnotation] {
        mutex.lock(); defer { mutex.unlock() }
        return try query("SELECT payload FROM annotations WHERE item_id=? ORDER BY rowid", strings: [itemID]).map { try decoder.decode(ReaderAnnotation.self, from: $0) }
    }
    public func saveAnnotation(_ annotation: ReaderAnnotation) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard try item(id: annotation.itemID) != nil else { throw LibraryError.invalid("The annotation's document does not exist.") }
        let data = try encoder.encode(annotation)
        try transaction {
            let statement = try prepare("INSERT INTO annotations(id,item_id,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload WHERE item_id=excluded.item_id")
            defer { sqlite3_finalize(statement) }
            bind(annotation.id, to: statement, at: 1); bind(annotation.itemID, to: statement, at: 2); bind(data, to: statement, at: 3)
            try stepDone(statement)
            guard sqlite3_changes(db) > 0 else { throw LibraryError.invalid("An annotation identifier belongs to a different document.") }
        }
        dirtySinceBackup = true
        automaticBackupIfNeeded()
    }
    public func deleteAnnotation(id: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        try transaction {
            let statement = try prepare("DELETE FROM annotations WHERE id=?"); defer { sqlite3_finalize(statement) }
            bind(id, to: statement, at: 1); try stepDone(statement)
        }
        dirtySinceBackup = true
        automaticBackupIfNeeded()
    }
    public func search(_ query: String) throws -> [LibraryItem] {
        mutex.lock(); defer { mutex.unlock() }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return try items() }
        return try items().filter { item in
            let notes = try annotations(itemID: item.id).map { $0.note + " " + $0.quote }.joined(separator: " ")
            let haystack = [item.title, item.author ?? "", item.text, item.tags.joined(separator: " "), item.sourceDomain ?? "", notes].joined(separator: " ")
            return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
    }

    /// A complete snapshot created with SQLite's backup API, never a live DB file copy.
    @discardableResult public func backup() throws -> URL {
        mutex.lock(); defer { mutex.unlock() }
        let destination = try createSnapshot(prefix: "Reader")
        lastBackupAt = Date(); lastBackupError = nil; dirtySinceBackup = false
        return destination
    }
    public func exportLibrary(to destination: URL) throws {
        mutex.lock(); defer { mutex.unlock() }
        let target = destination.standardizedFileURL
        guard !target.path.hasPrefix(root.path + "/Items/") else { throw LibraryError.invalid("Choose an export location outside Items.") }
        try snapshot(to: target)
    }
    public static func restore(from snapshot: URL, to destination: URL) throws {
        let fm = FileManager.default, source = snapshot.standardizedFileURL, target = destination.standardizedFileURL
        guard !target.path.hasPrefix(source.path + "/") else { throw LibraryError.invalid("Restore into a separate folder outside the backup.") }
        guard !fm.fileExists(atPath: target.path) else { throw LibraryError.invalid("Restore requires a new, absent destination folder. Existing libraries are never overwritten.") }
        try verifySnapshot(source)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".Reader-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for name in ["Library.sqlite", "Library.json", "Items"] { try fm.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name)) }
            try fm.createDirectory(at: staging.appendingPathComponent("Backups"), withIntermediateDirectories: false)
            try fm.createDirectory(at: staging.appendingPathComponent("Exports"), withIntermediateDirectories: false)
            let verified = try LibraryStore(root: staging)
            try verified.validateContent()
            verified.close()
            try fm.moveItem(at: staging, to: target)
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    public func exportMarkdown(to destination: URL) throws {
        mutex.lock(); defer { mutex.unlock() }
        var output = "# Reader notes and highlights\n\nExported \(ISO8601DateFormatter().string(from: Date()))\n\n"
        for item in try items() {
            let entries = try annotations(itemID: item.id)
            guard !entries.isEmpty else { continue }
            output += "## \(item.title.replacingOccurrences(of: "\n", with: " "))\n\n"
            output += "- ID: \(item.id)\n- Type: \(item.kind.rawValue)\n- Local file: Items/\(item.id)/\(item.contentPath)\n"
            if let narration = item.narration {
                output += "- Narration audio: Items/\(item.id)/\(narration.relativeAudioPath)\n"
                output += "- Narration script: Items/\(item.id)/\(narration.relativeScriptPath)\n"
                output += "- Narration voice/speed: \(narration.voice) / \(narration.speed)\n"
            }
            if let author = item.author { output += "- Author: \(author)\n" }
            if let url = item.originalURL { output += "- Source: \(url)\n" }
            output += "- Added: \(ISO8601DateFormatter().string(from: item.addedAt))\n"
            if !item.tags.isEmpty { output += "- Tags: \(item.tags.joined(separator: ", "))\n" }
            output += "\n"
            for note in entries {
                if let page = note.pdfRects.first?.pageIndex ?? note.pdfAnchor?.pageIndex { output += "Page \(page + 1)\n\n" }
                if !note.quote.isEmpty { output += note.quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n" }
                if !note.note.isEmpty { output += note.note + "\n\n" }
                output += "---\n\n"
            }
        }
        try Data(output.utf8).write(to: destination, options: .atomic)
    }

    public func validateContent() throws {
        mutex.lock(); defer { mutex.unlock() }
        try validateDatabase()
        for item in try items() {
            let file = try contentURL(for: item)
            guard fm.isReadableFile(atPath: file.path) else { throw LibraryError.invalid("Missing content for \(item.title): \(file.lastPathComponent)") }
            _ = try annotations(itemID: item.id)
            if item.narration != nil {
                guard let audio = try narrationAudioURL(for: item), let script = try narrationScriptURL(for: item),
                      fm.isReadableFile(atPath: audio.path), fm.isReadableFile(atPath: script.path) else {
                    throw LibraryError.invalid("Missing narration audio or script for \(item.title).")
                }
                for file in [audio, script] {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw LibraryError.invalid("Narration audio or script is empty for \(item.title).") }
                }
            }
        }
    }

    private func automaticBackupIfNeeded() {
        guard lastBackupAt.map({ Date().timeIntervalSince($0) >= 15 * 60 }) ?? true else { return }
        do { _ = try backup() } catch { lastBackupError = error.localizedDescription }
    }
    private func createSnapshot(prefix: String) throws -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let directory = root.appendingPathComponent("Backups")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
        try snapshot(to: target)
        return target
    }
    private func snapshot(to destination: URL) throws {
        guard db != nil, !closed else { throw LibraryError.database("The library is closed.") }
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.invalid("The export destination already exists. Choose a new name.") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".Reader-snapshot-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let items = root.appendingPathComponent("Items")
            if fm.fileExists(atPath: items.path) { try fm.copyItem(at: items, to: staging.appendingPathComponent("Items")) }
            else { try fm.createDirectory(at: staging.appendingPathComponent("Items"), withIntermediateDirectories: true) }
            let marker = root.appendingPathComponent("Library.json")
            if fm.fileExists(atPath: marker.path) { try fm.copyItem(at: marker, to: staging.appendingPathComponent("Library.json")) }
            else { try Data("{\"format\":\"Reader Library\",\"version\":1}".utf8).write(to: staging.appendingPathComponent("Library.json")) }
            try backupDatabase(to: staging.appendingPathComponent("Library.sqlite"))
            let manifest = SnapshotManifest(formatVersion: 1, createdAt: Date(), files: try Self.fileDigests(in: staging))
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("Snapshot.json"), options: .atomic)
            try Self.verifySnapshot(staging)
            try fm.moveItem(at: staging, to: destination)
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    private func backupDatabase(to destination: URL) throws {
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let target { sqlite3_close(target) }; throw LibraryError.database("Cannot open the backup database.")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else { throw LibraryError.database("Cannot start a consistent SQLite backup.") }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw LibraryError.database("The SQLite backup did not complete (\(result)).") }
    }
    public static func verifySnapshot(_ root: URL) throws {
        let decoder = JSONDecoder()
        let manifestURL = root.appendingPathComponent("Snapshot.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw LibraryError.invalid("This folder is not a complete Reader snapshot (Snapshot.json is missing).") }
        try validateTree(root)
        let manifest = try decoder.decode(SnapshotManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == 1 else { throw LibraryError.invalid("Unsupported snapshot format.") }
        let actual = try fileDigests(in: root)
        guard actual == manifest.files else {
            let differences = Set(actual.keys).union(manifest.files.keys).filter { actual[$0] != manifest.files[$0] }.sorted().joined(separator: ", ")
            throw LibraryError.invalid("The backup's file hashes do not match (\(differences)). Nothing was restored.")
        }
        guard actual["Library.sqlite"] != nil, actual["Library.json"] != nil else { throw LibraryError.invalid("The backup is incomplete.") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("Library.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw LibraryError.invalid("The backup database cannot be opened.")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else { throw LibraryError.invalid("Cannot validate the backup database.") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let result = sqlite3_column_text(statement, 0), String(cString: result) == "ok" else { throw LibraryError.invalid("The backup database failed SQLite integrity checks.") }
    }
    private static func validateTree(_ directory: URL) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        let rootValues = try directory.resourceValues(forKeys: Set(keys))
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { throw LibraryError.invalid("The content folder must be a real directory.") }
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: keys, options: []) else { throw LibraryError.invalid("The content directory cannot be read.") }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw LibraryError.invalid("Library content must contain ordinary files and folders, without symbolic links.") }
        }
    }
    private static func fileDigests(in root: URL) throws -> [String: String] {
        // Foundation enumeration resolves /var to /private/var. Normalize before deriving
        // relative names so snapshot manifests are independent of that filesystem alias.
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var result: [String: String] = [:]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw LibraryError.invalid("Cannot inspect snapshot files.") }
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let normalizedPath = file.standardizedFileURL.path
            guard normalizedPath.hasPrefix(root.path + "/") else { throw LibraryError.invalid("Unexpected snapshot path.") }
            let path = String(normalizedPath.dropFirst(root.path.count + 1))
            if path == "Snapshot.json" { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            result[path] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    private func validate(_ item: LibraryItem) throws {
        guard !item.id.isEmpty, item.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !item.contentPath.isEmpty,
              !item.contentPath.hasPrefix("/"), !item.contentPath.split(separator: "/").contains("..") else { throw LibraryError.invalid("Unsafe item identifier or content path.") }
        if let narration = item.narration {
            guard !narration.id.isEmpty, narration.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                  narration.relativeAudioPath == "Narrations/\(narration.id)/audio.mp3",
                  narration.relativeScriptPath == "Narrations/\(narration.id)/script.txt",
                  narration.speed.isFinite, narration.speed > 0, narration.playbackPosition.isFinite, narration.playbackPosition >= 0,
                  narration.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw LibraryError.invalid("Unsafe narration record or content path.") }
        }
    }
    private func writeItem(_ item: LibraryItem, insert: Bool) throws {
        let statement = try prepare(insert ? "INSERT INTO items(payload,canonical_url,added,id) VALUES(?,?,?,?)" : "UPDATE items SET payload=?,canonical_url=?,added=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(try encoder.encode(item), to: statement, at: 1)
        if let url = item.originalURL.flatMap(URL.init(string:)) { bind(Self.canonicalURL(url), to: statement, at: 2) } else { sqlite3_bind_null(statement, 2) }
        sqlite3_bind_double(statement, 3, item.addedAt.timeIntervalSince1970); bind(item.id, to: statement, at: 4)
        try stepDone(statement)
    }
    private func validateDatabase() throws {
        let statement = try prepare("PRAGMA quick_check"); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let string = sqlite3_column_text(statement, 0), String(cString: string) == "ok" else { throw LibraryError.invalid("SQLite integrity checks failed. Preserve this library and restore a verified backup into a separate folder.") }
    }
    private func databaseError() -> LibraryError { .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "The library is closed.") }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db, !closed else { throw LibraryError.database("The library is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard let db, !closed else { throw LibraryError.database("The library is closed.") }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int(statement, 0))
    }
    private func query(_ sql: String, strings: [String] = []) throws -> [Data] {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        for (index, value) in strings.enumerated() { bind(value, to: statement, at: Int32(index + 1)) }
        var result: [Data] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw databaseError() }
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0) { result.append(Data(bytes: bytes, count: count)) }
            else { result.append(Data()) }
        }
        return result
    }
    private func bind(_ string: String, to statement: OpaquePointer, at index: Int32) { _ = string.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } }
    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient) } }
    private func stepDone(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() } }
}

private struct SnapshotManifest: Codable {
    var formatVersion: Int
    var createdAt: Date
    var files: [String: String]
}

private struct LibraryMarker: Decodable {
    let format: String
    let version: Int
}
