import Foundation
import AppKit
import WebKit
import PDFKit
import ReaderCore

/// Deterministic, opt-in verification. Uses only a newly created temporary library.
/// Run scripts/fixture-server.py, then Reader --verify-imports.
@MainActor
enum ImportVerification {
    static func run() async -> Bool {
        let base = URL(string: ProcessInfo.processInfo.environment["READER_FIXTURE_BASE_URL"] ?? "http://127.0.0.1:8766")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderVerification-\(UUID().uuidString)")
        var checks: [String] = []
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw ImportFailure.extraction("Verification failed: \(message)") }
            checks.append(message)
            print("PASS: \(message)")
        }
        do {
            let importer = ArticleImporter()
            let article = try await importer.prepare(url: base.appendingPathComponent("redirect"))
            defer { article.cleanup() }
            try check(article.kind == .article && article.text.contains("persimmon"), "Redirected article extracted with searchable text")
            try check(article.originalURL == base.appendingPathComponent("article.html").absoluteString, "Final redirect URL retained")
            let html = try String(contentsOf: article.directory.appendingPathComponent(article.contentPath), encoding: .utf8)
            try check(!html.contains("<script") && !html.contains("<iframe") && !html.contains("onclick") && !html.contains("javascript:"), "Article scripts, event handlers, unsafe links and frames removed")
            try check(FileManager.default.fileExists(atPath: article.directory.appendingPathComponent("images/0.png").path), "Article image cached locally")
            try check(!article.warnings.isEmpty, "Missing image reports a recoverable warning")
            try check(!html.contains("src=\"http"), "Saved article has no remote image dependency")
            let pdf = try await importer.prepare(url: base.appendingPathComponent("reading-fixture.pdf"))
            defer { pdf.cleanup() }
            let pdfURL = pdf.directory.appendingPathComponent(pdf.contentPath)
            let pdfData = try Data(contentsOf: pdfURL)
            let importedFile = try await importer.preparePDF(fileURL: pdfURL)
            defer { importedFile.cleanup() }
            try check(pdf.kind == .pdf && pdf.text.contains("persimmon"), "URL PDF detected and text layer indexed")
            try check(try Data(contentsOf: importedFile.directory.appendingPathComponent(importedFile.contentPath)) == pdfData, "File PDF copied intact")
            for endpoint in ["unavailable", "unsupported"] {
                var failed = false
                do { let unexpected = try await importer.prepare(url: base.appendingPathComponent(endpoint)); unexpected.cleanup() }
                catch { failed = true }
                try check(failed, "\(endpoint) import fails clearly")
            }
            let store = try LibraryStore(root: root, createIfMissing: true)
            defer { store.close() }
            let item = ReaderCore.LibraryItem(title: article.title, kind: article.kind, author: article.author,
                                              originalURL: article.originalURL, sourceDomain: base.host,
                                              contentPath: article.contentPath, text: article.text, tags: ["fixture"])
            let pdfItem = ReaderCore.LibraryItem(title: pdf.title, kind: .pdf, contentPath: pdf.contentPath, text: pdf.text)
            try store.addItem(item, from: article.directory)
            try store.addItem(pdfItem, from: pdf.directory)
            let managedURL = try store.contentURL(for: item)
            try check(managedURL.path.hasPrefix(root.path), "Managed article content is inside configured library")
            let view = try await VerificationWebView.open(managedURL)
            defer { view.close() }
            let anchor = try await view.selectSecondOccurrence()
            try check(anchor.exact == "This sentence is repeated on purpose." && anchor.suffix.contains("second occurrence"), "Actual WebKit selection captures quote, context and position")
            let annotation = ReaderAnnotation(itemID: item.id, quote: anchor.exact, note: "A persistent fixture note", articleAnchor: anchor)
            try store.saveAnnotation(annotation)
            try await view.render([annotation])
            try check(try await view.markIsInSecondParagraph(), "Article highlight resolves the correct repeated passage")
            var moved = annotation
            moved.articleAnchor?.start = 0
            try await view.render([moved])
            try check(try await view.markIsInSecondParagraph(), "Context anchoring survives a stale position hint")
            try check(try await view.jump(annotation.id), "Article annotation navigation finds the marked passage")
            try await view.appearance(dark: true)
            try check(try await view.isDark(), "Reader typography and dark appearance apply in WebKit")
            try await view.appearance(dark: false)
            try check(!(try await view.isDark()), "Reader light appearance applies in WebKit")
            try store.saveProgress(itemID: item.id, progress: ReadingProgress(fraction: 0.63))
            store.close()
            let reopened = try LibraryStore(root: root)
            defer { reopened.close() }
            let restoredItem = try reopened.item(id: item.id)!
            let restoredNotes = try reopened.annotations(itemID: item.id)
            try check(restoredNotes.count == 1 && restoredNotes.first?.note == annotation.note, "Article note and anchor persist after database close/reopen")
            try check(abs(restoredItem.progress.fraction - 0.63) < 0.001, "Reading progress persists after reopen")
            try check(try reopened.duplicate(forURL: URL(string: article.originalURL! + "#fragment")!)?.id == item.id, "Duplicate URL resolves existing item")
            let offline = try await VerificationWebView.open(try reopened.contentURL(for: restoredItem))
            defer { offline.close() }
            try await offline.render(restoredNotes)
            try check(try await offline.markIsInSecondParagraph(), "Reopened local article renders persisted highlight with all HTTP requests blocked")
            try check(try await offline.imageIsLoaded(), "Managed local image renders from disk")
            let snapshot = root.deletingLastPathComponent().appendingPathComponent("ReaderSnapshot-\(UUID().uuidString)")
            let restore = root.deletingLastPathComponent().appendingPathComponent("ReaderRestore-\(UUID().uuidString)")
            try reopened.exportLibrary(to: snapshot)
            try LibraryStore.restore(from: snapshot, to: restore)
            let recovered = try LibraryStore(root: restore)
            defer { recovered.close() }
            try recovered.validateContent()
            try check(try recovered.items().count == 2 && recovered.annotations(itemID: item.id).count == 1, "Complete-library export restores content and annotations into separate folder")
            print("VERIFICATION PASSED: \(checks.count) checks. Temporary library: \(root.path)")
            return true
        } catch {
            print("VERIFICATION FAILED: \(error.localizedDescription)")
            print("Temporary library, if created: \(root.path)")
            return false
        }
    }
}

@MainActor
private final class VerificationWebView: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var pending: CheckedContinuation<Void, Error>?
    private init(view: WKWebView) { self.view = view; super.init(); view.navigationDelegate = self }
    static func open(_ url: URL) async throws -> VerificationWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // A real WebKit content blocker makes the reopened reader's network unavailable.
        // Local files remain available, so text, highlights and cached images must stand alone.
        let blocker: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ReaderVerificationOffline", encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]") { rule, error in
                if let rule { continuation.resume(returning: rule) }
                else { continuation.resume(throwing: error ?? ImportFailure.extraction("Unable to create offline verification blocker")) }
            }
        }
        configuration.userContentController.add(blocker)
        let scriptURL = ReaderResources.bundle.url(forResource: "Reader", withExtension: "js", subdirectory: "Resources")!
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let wrapper = VerificationWebView(view: WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            wrapper.pending = c
            wrapper.view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wrapper
    }
    func close() { view.stopLoading(); view.navigationDelegate = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let c = pending; pending = nil; c?.resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { let c = pending; pending = nil; c?.resume(throwing: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { let c = pending; pending = nil; c?.resume(throwing: error) }
    func selectSecondOccurrence() async throws -> ArticleAnchor {
        let result = try await view.callAsyncJavaScript("""
        const root=document.getElementById('reader-content'), phrase='This sentence is repeated on purpose.';
        const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);let node,count=0;
        while(node=walker.nextNode()){const i=node.textContent.indexOf(phrase);if(i>=0&&++count===2){const range=document.createRange();range.setStart(node,i);range.setEnd(node,i+phrase.length);const s=getSelection();s.removeAllRanges();s.addRange(range);break;}}
        return window.ReaderAPI.selection();
        """, arguments: [:], in: nil, contentWorld: .page)
        guard let result = result as? [String: Any], JSONSerialization.isValidJSONObject(result) else { throw ImportFailure.extraction("No fixture selection") }
        return try JSONDecoder().decode(ArticleAnchor.self, from: JSONSerialization.data(withJSONObject: result))
    }
    func render(_ annotations: [ReaderAnnotation]) async throws {
        let json = String(data: try JSONEncoder().encode(annotations), encoding: .utf8)!
        _ = try await view.evaluateJavaScript("window.ReaderAPI.render(\(json))")
    }
    func markIsInSecondParagraph() async throws -> Bool { (try await view.evaluateJavaScript("document.querySelector('mark')?.closest('p')?.textContent.includes('second occurrence') || false")) as? Bool ?? false }
    func jump(_ id: String) async throws -> Bool {
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [id]), encoding: .utf8)!
        return (try await view.evaluateJavaScript("window.ReaderAPI.jump(\(encoded)[0])")) as? Bool ?? false
    }
    func appearance(dark: Bool) async throws { _ = try await view.evaluateJavaScript("window.ReaderAPI.appearance(23,1.8,640,\(dark ? "true" : "false"))") }
    func isDark() async throws -> Bool { (try await view.evaluateJavaScript("document.documentElement.dataset.theme === 'dark' && getComputedStyle(document.body).fontSize === '23px'")) as? Bool ?? false }
    func imageIsLoaded() async throws -> Bool {
        // Wait for local raster decode without permitting any remote page request.
        (try await view.callAsyncJavaScript("for(const img of document.images){if(img.getAttribute('src')){await img.decode();return img.naturalWidth>0;}}return false;", arguments: [:], in: nil, contentWorld: .page)) as? Bool ?? false
    }
}
