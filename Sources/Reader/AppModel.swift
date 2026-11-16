import SwiftUI
import AppKit
import Combine
import ReaderCore

struct ImportJob: Identifiable {
    let id = UUID()
    let url: URL
    var status = "Waiting"
    var existingID: String?
    var failed = false
    var complete = false
}
enum LibrarySection: String, CaseIterable, Identifiable {
    case inbox = "Inbox", all = "All items", favorites = "Favourites", archive = "Archive", trash = "Trash"
    var id: String { rawValue }
    var icon: String { switch self { case .inbox: return "tray"; case .all: return "books.vertical"; case .favorites: return "star"; case .archive: return "archivebox"; case .trash: return "trash" } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ReaderItem] = []
    @Published var annotations: [ReaderAnnotation] = []
    @Published var selectedID: String?
    @Published var section: LibrarySection = .inbox
    @Published var query = ""
    @Published var tagFilter: String?
    @Published var error: String?
    @Published var libraryError: String?
    @Published var status = "Saved locally"
    @Published var showImport = false
    @Published var showNarration = false
    let narrator = NarrationController()
    private var narratorObservation: AnyCancellable?
    @Published var jobs: [ImportJob] = []
    @Published var importing = false
    @Published var showNotes = true
    @Published var focusedReading = false
    @Published var lastAnnotationID: String?
    @Published var libraryPath = ""
    @AppStorage("appearance") var appearance = "system"
    @AppStorage("articleFontSize") var fontSize = 19.0
    @AppStorage("articleLineSpacing") var lineSpacing = 1.65
    @AppStorage("articleReadingWidth") var readingWidth = 720.0
    var store: LibraryStore?
    let importer = ArticleImporter()
    var pendingAnnotations: [String: ReaderAnnotation] = [:]
    var lastProgress: [String: ReadingProgress] = [:]
    var ephemeral = false
    var selectedItem: ReaderItem? { items.first { $0.id == selectedID } }
    var allTags: [String] { Array(Set(items.filter { $0.trashedAt == nil }.flatMap(\.tags))).sorted() }
    var visibleItems: [ReaderItem] {
        var matches = items.filter { item in
            switch section {
            case .inbox: return item.trashedAt == nil && !item.isArchived && item.status != .finished
            case .all: return item.trashedAt == nil
            case .favorites: return item.trashedAt == nil && item.isFavorite
            case .archive: return item.trashedAt == nil && item.isArchived
            case .trash: return item.trashedAt != nil
            }
        }
        if let tagFilter { matches = matches.filter { $0.tags.contains(tagFilter) } }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ids = Set((try? store?.search(query).map(\.id)) ?? [])
            matches = matches.filter { ids.contains($0.id) }
        }
        return matches
    }
    init() {
        narrator.onSaved = { [weak self] in
            guard let self else { return }
            do { try self.refresh(); self.status = "Narration saved in library" } catch { self.error = error.localizedDescription }
        }
        narratorObservation = narrator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--verify-imports") || args.contains("--verify-reading") || args.contains("--verify-narration") { ephemeral = true; return }
        let explicit = args.firstIndex(of: "--library").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        ephemeral = explicit != nil
        let saved = UserDefaults.standard.string(forKey: "libraryPath")
        let path = explicit ?? saved ?? LibraryStore.defaultRoot.path
        openLibrary(URL(fileURLWithPath: path), create: explicit != nil ? args.contains("--create-library") : saved == nil)
    }
    func openLibrary(_ root: URL, create: Bool = false) {
        guard !importing && !narrator.isBusy else { error = "Wait for imports and narration to finish before switching libraries."; return }
        guard flushPending() else { return }
        do {
            if root.standardizedFileURL == store?.root.standardizedFileURL { return }
            let next = try LibraryStore(root: root, createIfMissing: create)
            narrator.stopPlayback()
            store?.close()
            store = next; libraryPath = root.path
            if !ephemeral { UserDefaults.standard.set(root.path, forKey: "libraryPath") }
            libraryError = nil; selectedID = nil; annotations = []
            try refresh()
            saved()
        } catch { libraryPath = root.path; libraryError = error.localizedDescription }
    }
    func refresh() throws { items = try store?.items() ?? [] }
    func select(_ id: String?) {
        guard flushPending() else { return }
        do {
            let loaded = try id.map { try store?.annotations(itemID: $0) ?? [] } ?? []
            selectedID = id; annotations = loaded
        } catch { self.error = error.localizedDescription }
    }
    func update(_ item: ReaderItem) {
        do { try store?.updateItem(item); try refresh(); saved() }
        catch { self.error = error.localizedDescription; status = "Save failed" }
    }
    func mutate(_ item: ReaderItem, _ body: (inout ReaderItem) -> Void) { var next = item; body(&next); update(next) }
    func save(_ annotation: ReaderAnnotation) {
        var annotation = annotation; annotation.updatedAt = Date()
        pendingAnnotations[annotation.id] = annotation
        if let i = annotations.firstIndex(where: { $0.id == annotation.id }) { annotations[i] = annotation }
        else { annotations.append(annotation) }
        _ = flushPending()
    }
    @discardableResult func flushPending() -> Bool {
        guard let store else { return true }
        do {
            for annotation in pendingAnnotations.values { try store.saveAnnotation(annotation) }
            pendingAnnotations.removeAll()
            saved(); return true
        } catch { self.error = "Your note is still in memory. Reader will keep it open until it can be saved.\n\n\(error.localizedDescription)"; status = "Save failed — retry required"; return false }
    }
    func addAnnotation(_ annotation: ReaderAnnotation) {
        save(annotation); showNotes = true; lastAnnotationID = annotation.id
    }
    func deleteAnnotation(_ annotation: ReaderAnnotation) {
        do { try store?.deleteAnnotation(id: annotation.id); pendingAnnotations.removeValue(forKey: annotation.id); annotations.removeAll { $0.id == annotation.id }; saved() }
        catch { self.error = error.localizedDescription }
    }
    func progress(id: String, value: ReadingProgress) {
        func sameCoordinate(_ first: Double?, _ second: Double?) -> Bool {
            switch (first, second) {
            case (nil, nil): return true
            case let (first?, second?): return abs(first - second) < 1.0
            default: return false
            }
        }
        if let previous = lastProgress[id], previous.pageIndex == value.pageIndex, abs(previous.fraction - value.fraction) < 0.002, abs(previous.zoom - value.zoom) < 0.01, previous.pageRotation == value.pageRotation,
           sameCoordinate(previous.pdfX, value.pdfX), sameCoordinate(previous.pdfY, value.pdfY) { return }
        do {
            try store?.saveProgress(itemID: id, progress: value)
            lastProgress[id] = value
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].progress = value; if items[index].status == .unread && (value.fraction > 0.001 || value.pageIndex > 0) { items[index].status = .reading } }
            if let backupError = store?.lastBackupError { status = "Saved · backup needs attention: " + backupError }
        } catch { status = "Reading position could not be saved"; self.error = error.localizedDescription }
    }
    func saved() { status = store?.lastBackupError.map { "Saved · backup needs attention: " + $0 } ?? ("Saved locally · " + Date().formatted(date: .omitted, time: .shortened)) }
    func pickPDFs() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        present(panel) { [weak self] response in if response == .OK { self?.queue(panel.urls) } }
    }
    func queueText(_ input: String) {
        let entries = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var urls: [URL] = []
        for entry in entries {
            if let url = URL(string: entry), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { urls.append(url) }
            else { jobs.append(ImportJob(url: URL(string: "about:blank")!, status: "Invalid URL: \(entry)", failed: true, complete: true)) }
        }
        queue(urls)
    }
    func queue(_ urls: [URL]) {
        guard store != nil, libraryError == nil else { error = "Locate or restore your library before importing."; return }
        showImport = true
        jobs.append(contentsOf: urls.map { ImportJob(url: $0) })
        startQueue()
    }
    func startQueue() {
        guard !importing, store != nil else { return }
        importing = true
        Task {
            while let index = jobs.firstIndex(where: { !$0.complete }) {
                let jobID = jobs[index].id
                jobs[index].status = "Importing…"
                do {
                    let requested = jobs[index].url
                    if !requested.isFileURL, let existing = items.first(where: { canonical($0.originalURL) == canonical(requested.absoluteString) }) {
                        finish(jobID, status: existing.trashedAt == nil ? "Already saved — open existing" : "Already in Trash — restore existing", existing: existing.id)
                        continue
                    }
                    let prepared = try await (requested.isFileURL ? importer.preparePDF(fileURL: requested) : importer.prepare(url: requested))
                    defer { prepared.cleanup() }
                    if let existing = items.first(where: { canonical($0.originalURL) != nil && canonical($0.originalURL) == canonical(prepared.originalURL) }) {
                        finish(jobID, status: "Already saved — open existing", existing: existing.id); continue
                    }
                    // Compare PDF bytes as well as URLs; originals stay immutable.
                    if prepared.kind == .pdf, let existing = try await duplicatePDF(prepared) {
                        finish(jobID, status: "This PDF is already saved — open existing", existing: existing.id); continue
                    }
                    let item = ReaderItem(title: prepared.title, kind: prepared.kind, author: prepared.author, originalURL: prepared.originalURL, sourceDomain: prepared.originalURL.flatMap { URL(string: $0)?.host }, contentPath: prepared.contentPath, text: prepared.text)
                    if let store { try await Task.detached(priority: .userInitiated) { try store.addItem(item, from: prepared.directory) }.value }
                    try refresh(); select(item.id)
                    finish(jobID, status: prepared.warnings.isEmpty ? "Saved offline" : "Saved · " + prepared.warnings.joined(separator: " "), existing: item.id)
                    saved()
                } catch { finish(jobID, status: error.localizedDescription, failed: true) }
            }
            importing = false
        }
    }
    func duplicatePDF(_ prepared: PreparedImport) async throws -> ReaderItem? {
        let items = items; let store = store
        return try await Task.detached(priority: .userInitiated) {
        let incoming = try Data(contentsOf: prepared.directory.appendingPathComponent(prepared.contentPath), options: .mappedIfSafe)
        for item in items where item.kind == .pdf {
            if let url = try? store?.contentURL(for: item), let existing = try? Data(contentsOf: url, options: .mappedIfSafe), existing == incoming { return item }
        }
        return nil
        }.value
    }
    func finish(_ id: UUID, status: String, failed: Bool = false, existing: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = status; jobs[i].failed = failed; jobs[i].complete = true; jobs[i].existingID = existing
    }
    func retry(_ id: UUID) { if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].url.scheme != "about" { jobs[i].complete = false; jobs[i].failed = false; startQueue() } }
    func canonical(_ string: String?) -> String? {
        guard let string, let url = URL(string: string) else { return nil }
        return LibraryStore.canonicalURL(url)
    }
    // Asynchronous panels avoid nesting AppKit's event loop inside menu actions.
    private func present(_ panel: NSSavePanel, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        panel.begin { response in MainActor.assumeIsolated { completion(response) } }
    }
    func locateLibrary() {
        guard !importing && !narrator.isBusy else { error = "Wait for imports and narration to finish before switching libraries."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose an existing Reader library folder."
        present(panel) { [weak self] response in
            if response == .OK, let url = panel.url { self?.openLibrary(url) }
        }
    }
    func reveal() { NSWorkspace.shared.open(URL(fileURLWithPath: libraryPath)) }
    func backup() {
        do { let url = try store?.backup(); status = "Backup created"; if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        catch { self.error = error.localizedDescription }
    }
    func exportLibrary() {
        let panel = NSSavePanel(); panel.directoryURL = store?.root.appendingPathComponent("Exports")
        panel.title = "Export complete Reader library"; panel.nameFieldStringValue = "Reader Export \(Self.timestamp())"; panel.canCreateDirectories = true
        present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.store?.exportLibrary(to: url); self.status = "Library exported"; NSWorkspace.shared.activateFileViewerSelecting([url]) }
            catch { self.error = error.localizedDescription }
        }
    }
    func exportNotes() {
        let panel = NSSavePanel(); panel.directoryURL = store?.root.appendingPathComponent("Exports")
        panel.nameFieldStringValue = "Reader Notes.md"; panel.allowedContentTypes = [.plainText]; panel.allowsOtherFileTypes = true
        present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { try self.store?.exportMarkdown(to: url); self.status = "Notes exported" }
            catch { self.error = error.localizedDescription }
        }
    }
    func restore() {
        guard !importing && !narrator.isBusy else { error = "Wait for imports and narration to finish before restoring a library."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a Reader backup or complete library export."; panel.prompt = "Choose backup"
        present(panel) { [weak self] response in
            guard let self, response == .OK, let source = panel.url else { return }
            let destination = NSSavePanel(); destination.title = "Restore into a new folder"
            destination.nameFieldStringValue = "Reader Restored \(Self.timestamp())"
            self.present(destination) { [weak self] response in
                guard let self, response == .OK, let target = destination.url else { return }
                do { try LibraryStore.restore(from: source, to: target); self.openLibrary(target); self.status = "Restored library opened" }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    static func timestamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"; return f.string(from: Date()) }
}
