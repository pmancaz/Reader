import AppKit
import WebKit
import PDFKit
import CryptoKit
import ReaderCore

/// Tests use a new library and local fixture website, never the personal library or printer.
@MainActor enum PrintingVerification {
    static func run() async -> Bool {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let output = ProcessInfo.processInfo.environment["READER_PRINT_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("ReaderPrintChecks-\(UUID().uuidString)")
        let scratch = fm.temporaryDirectory.appendingPathComponent("ReaderPresentationChecks-\(UUID().uuidString)")
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LibraryError.invalid("Verification failed: " + message) }
            count += 1; print("PASS: " + message)
        }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<300 { if condition() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
            throw LibraryError.io("A presentation check timed out.")
        }
        func save(_ item: ReaderItem, url: URL, to output: URL) async throws -> PDFDocument {
            let info = DocumentPrinter.a4PrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
            let prepared = try await DocumentPrinter.prepare(item, url: url, printInfo: info)
            prepared.operation.showsPrintPanel = false; prepared.operation.showsProgressPanel = false
            print("Preparing native print: \(item.kind), \(String(describing: prepared.operation.view?.frame))")
            let completed = await PrintCheckCompletion.run(prepared.operation)
            guard completed, let document = PDFDocument(url: output) else { throw LibraryError.io("The print operation did not produce a readable PDF.") }
            return document
        }
        func isA4(_ document: PDFDocument) -> Bool {
            (0..<document.pageCount).allSatisfy { index in
                guard let page = document.page(at: index) else { return false }
                let box = page.bounds(for: .mediaBox)
                return abs(box.width - 595.276) < 1 && abs(box.height - 841.89) < 1
            }
        }
        do {
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            let stage = scratch.appendingPathComponent("stage")
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            let markers = (1...24).map { String(format: "paragraph%03dend", $0) }
            let sentence = "A printed passage should keep its place on the page. Clear margins and ordinary line breaks help an idea travel from a screen to a sheet of paper. "
            let paragraphs = markers.enumerated().map { index, marker in "<h2>Section \(index + 1)</h2><p>" + String(repeating: sentence, count: 4) + " \(marker)</p>" }.joined()
            let table = "<table><thead><tr><th>Paper</th><th>Observation</th><th>Reference</th></tr></thead><tbody>" + (1...12).map { "<tr><td>Study \($0)</td><td>" + String(repeating: sentence, count: 2) + "</td><td>tableRow\($0)Complete</td></tr>" }.joined() + "</tbody></table>"
            let html = """
            <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file:; style-src 'unsafe-inline'">
            <title>A4 print verification</title><style>body{background:#222;color:white;width:1600px}main{height:400px;overflow:hidden}pre{white-space:pre;overflow:scroll}</style>
            <h1>A useful passage on paper</h1><main id="reader-content">\(paragraphs)
            <h2>A large figure</h2><figure><img src="figure.png" alt="Original tall test illustration"><figcaption>figureCaptionComplete</figcaption></figure>
            <h2>A table that spans pages</h2>\(table)
            <pre>codeStart\(String(repeating: "longUnbrokenCode", count: 24))codeEnd</pre>
            <p>https://example.org/\(String(repeating: "a-long-reference-", count: 28))referenceEnd</p>
            <p>FinalDocumentMarkerComplete</p></main>
            """
            let source = stage.appendingPathComponent("article.html")
            try Data(html.utf8).write(to: source)
            let image = NSImage(size: NSSize(width: 900, height: 2100))
            image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 900, height: 2100).fill()
            NSColor.systemOrange.setFill(); NSRect(x: 60, y: 60, width: 780, height: 1980).fill(); image.unlockFocus()
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: stage.appendingPathComponent("figure.png"))
            let base = URL(string: ProcessInfo.processInfo.environment["READER_FIXTURE_BASE_URL"] ?? "http://127.0.0.1:8766")!
            let item = ReaderItem(title: "A useful passage on paper", kind: .article, originalURL: base.appendingPathComponent("original.html").absoluteString, contentPath: "article.html", text: "offline paper text", tags: ["#Research"])
            let model = AppModel()
            model.openLibrary(scratch.appendingPathComponent("Library"), create: true)
            guard let store = model.store else { throw LibraryError.io("No fixture library") }
            defer { store.close() }
            try store.addItem(item, from: stage); try model.refresh(); model.select(item.id)
            model.section = .all; model.tagFilter = "Research"
            try check(model.visibleItems.map(\.id) == [item.id], "Legacy tags with a leading hash work with the new sidebar filter")
            model.tagFilter = nil
            let managed = try store.contentURL(for: item)
            let originalBytes = try Data(contentsOf: managed)
            let progress = ReadingProgress(fraction: 0.63)
            try store.saveProgress(itemID: item.id, progress: progress)
            let note = ReaderAnnotation(itemID: item.id, quote: "A printed passage", note: "Keep this response")
            try store.saveAnnotation(note)
            try check(model.updateTags(itemID: item.id, tags: ReaderTags.parse(" #research, Music, music, , #Creative   practice\nResearch")), "Dedicated tag editing saves successfully")
            guard let tagged = try store.item(id: item.id) else { throw LibraryError.invalid("Missing tagged item") }
            try check(Set(tagged.tags) == Set(["Research", "Music", "Creative practice"]), "Tags reuse existing names and remove empty/case duplicates")
            try check(tagged.progress == progress && (try store.annotations(itemID: item.id)) == [note], "Tag edits preserve the latest reading position and notes")
            model.section = .all; model.tagFilter = "music"
            try check(model.visibleItems.map(\.id) == [item.id], "Sidebar filtering finds tagged papers regardless of case")
            try check(try store.search("Creative practice").map(\.id) == [item.id], "New tags are available to library search")
            model.store?.close(); model.store = nil
            model.openLibrary(scratch.appendingPathComponent("Library"))
            try check(model.items.first?.tags == tagged.tags, "Tags persist after a complete library reopen")
            defer { model.store?.close() }

            let printed = try await save(item, url: managed, to: output.appendingPathComponent("article-a4.pdf"))
            try check(printed.pageCount > 5 && isA4(printed), "Long articles paginate onto separate A4 pages")
            let text = printed.string ?? ""
            let textHasMargins = (0..<printed.pageCount).allSatisfy { index in
                guard let page = printed.page(at: index), let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return false }
                let box = selection.bounds(for: page), paper = page.bounds(for: .mediaBox)
                return box.minX >= 40 && box.maxX <= paper.width - 40 && box.minY >= 38 && box.maxY <= paper.height - 38
            }
            try check(textHasMargins, "Printed article text stays inside safe margins on every page")
            try check(markers.allSatisfy { text.contains($0) } && text.contains("FinalDocumentMarkerComplete"), "Every paragraph and the final line survive pagination")
            // PDF text extraction may interleave table columns. Compare word counts
            // rather than assuming that the extracted reading order is prose order.
            func words(_ value: String) -> [String: Int] {
                value.lowercased().split(whereSeparator: { !$0.isLetter }).reduce(into: [:]) { $0[String($1), default: 0] += 1 }
            }
            let expectedWords = words(String(repeating: sentence, count: 120)), actualWords = words(text)
            try check(expectedWords.allSatisfy { actualWords[$0.key, default: 0] >= $0.value }, "All prose words from 120 body/table passages survive page breaks")
            try check((1...12).allSatisfy { text.contains("tableRow\($0)Complete") }, "Every table row survives printing across pages")
            try check(text.contains("figureCaptionComplete") && text.contains("codeEnd") && text.contains("referenceEnd"), "Figure caption, long code and long reference reach the print output")
            try check(try Data(contentsOf: managed) == originalBytes, "Printing leaves the saved article byte-for-byte intact")

            let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["READER_FIXTURE_PDF"] ?? fm.currentDirectoryPath + "/Tests/Fixtures/reading-fixture.pdf")
            let pdfBytes = try Data(contentsOf: fixture)
            let pdfItem = ReaderItem(title: "PDF on A4", kind: .pdf, contentPath: "original.pdf")
            let fitted = try await save(pdfItem, url: fixture, to: output.appendingPathComponent("pdf-a4.pdf"))
            try check(fitted.pageCount == 3 && isA4(fitted), "All original PDF pages, including a rotated page, fit onto A4")
            try check((1...3).allSatisfy { fitted.string?.contains("persimmon-\($0)") == true }, "Native PDF printing retains every page's selectable text")
            try check(try Data(contentsOf: fixture) == pdfBytes, "PDF fitting never rewrites the original document")

            let live = OriginalPageController()
            let web = live.makeView(); web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            defer { live.close(web) }
            live.load(item)
            try await wait { !live.isLoading }
            try check(live.error == nil, "Original website loads in the embedded view")
            let originalVisible = try await web.evaluateJavaScript("document.body.textContent.includes('Original website navigation') && window.originalFixtureScriptRan === true && !window.ReaderAPI && !window.webkit?.messageHandlers?.reader") as? Bool ?? false
            try check(originalVisible, "Original retains website layout/scripts without a Reader bridge")
            try check(web.configuration.websiteDataStore.isPersistent == false && !OriginalPageController.canLoad(URL(string: "file:///tmp/private")) && !OriginalPageController.canLoad(URL(string: "javascript:alert(1)")), "Original browsing uses an ephemeral store and rejects local/script navigation")
            web.load(URLRequest(url: base.appendingPathComponent("next.html")))
            try await wait { web.url?.path == "/next.html" && !web.isLoading }
            try check(web.canGoBack, "Original website keeps working back navigation")
            live.back(); try await wait { web.url?.path == "/original.html" && !web.isLoading }
            try check(web.url?.path == "/original.html", "Back returns to the original article")
            try check(try Data(contentsOf: managed) == originalBytes, "Original browsing leaves the offline Reader copy unchanged")

            let bridge = ReaderBridge(); bridge.item = item; bridge.isOriginal = true
            var readerRequested = false; bridge.onRequestReader = { readerRequested = true }
            bridge.navigate(to: note)
            try check(readerRequested && bridge.pendingNavigation?.id == note.id, "Selecting a saved note in Original requests Reader view before navigating")
            print("\(count) printing, tags and Original checks passed. PDFs: \(output.path)")
            return true
        } catch { print("FAIL: \(error.localizedDescription)"); return false }
    }
}

@MainActor private final class PrintCheckCompletion: NSObject {
    private var pending: CheckedContinuation<Bool, Never>?
    static func run(_ operation: NSPrintOperation) async -> Bool {
        let completion = PrintCheckCompletion()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let result = await withCheckedContinuation { continuation in
            completion.pending = continuation
            operation.runModal(for: window, delegate: completion, didRun: #selector(completion.finished(_:success:contextInfo:)), contextInfo: nil)
        }
        withExtendedLifetime(completion) {}
        return result
    }
    @objc private func finished(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        pending?.resume(returning: success); pending = nil
    }
}
